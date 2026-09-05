const { readResponseBytes } = require("./response-body.cjs");
const { createHash, randomUUID } = require("node:crypto");
const { spawn } = require("node:child_process");
const fs = require("node:fs/promises");
const path = require("node:path");

// The macOS updater intentionally does not use electron-updater. Its release
// contract is a small manifest plus a signed
// zip archive installed by the bundled `install-update.sh` helper.  Keep this
// module free of Electron dependencies so the validation and redirect gates
// can be exercised from Node tests on every host.
const MAC_UPDATE_MANIFEST_URL =
  "https://github.com/Drastics-Experiments/resonance/releases/latest/download/latest-mac.json";
const MAC_UPDATE_RELEASES_API_URL =
  "https://api.github.com/repos/Drastics-Experiments/resonance/releases?per_page=100";
const MAC_UPDATE_MAX_MANIFEST_BYTES = 256 * 1024;
const MAC_UPDATE_MAX_RELEASE_LIST_BYTES = 2 * 1024 * 1024;
const MAC_UPDATE_MAX_ARCHIVE_BYTES = 512 * 1024 * 1024;
const MAC_UPDATE_MAX_REDIRECTS = 5;
const MAC_UPDATE_HOSTS = new Set([
  "github.com",
  "objects.githubusercontent.com",
  "release-assets.githubusercontent.com",
  "github-releases.githubusercontent.com",
]);
const MAC_UPDATE_API_HOSTS = new Set(["api.github.com"]);
const SEMANTIC_VERSION = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:0|[1-9]\d*|[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;
const RELEASE_TAG_PATTERN = /^v((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))(?:-pre\.([1-9]\d{9,11}))?$/;
const RELEASE_ASSET_PREFIX = "/Drastics-Experiments/resonance/releases/download/";
const MAC_ARCHIVE_NAME = "Resonance-macOS.zip";

function normalizedVersion(value) {
  const version = String(value || "").trim().replace(/^v/i, "");
  return SEMANTIC_VERSION.test(version) ? version : null;
}

function parseMacReleaseTag(value) {
  const tag = String(value || "").trim();
  const match = RELEASE_TAG_PATTERN.exec(tag);
  if (!match) return null;
  const timestamp = match[2] ? Number(match[2]) : null;
  if (timestamp !== null && (!Number.isSafeInteger(timestamp) || timestamp <= 0)) return null;
  return Object.freeze({
    tag,
    version: match[1],
    prerelease: timestamp !== null,
    sourceTimestamp: timestamp,
  });
}

function releaseAssetURL(value, tag, assetName) {
  let url;
  try { url = new URL(String(value || "")); } catch { return null; }
  if (!allowsMacUpdateURL(url, new Set(["github.com"]))) return null;
  if (url.search || url.pathname !== `${RELEASE_ASSET_PREFIX}${tag}/${assetName}`) return null;
  return url;
}

function comparePrerelease(left, right) {
  const leftParts = left ? left.split(".") : [];
  const rightParts = right ? right.split(".") : [];
  if (!leftParts.length && !rightParts.length) return 0;
  if (!leftParts.length) return 1;
  if (!rightParts.length) return -1;
  const count = Math.max(leftParts.length, rightParts.length);
  for (let index = 0; index < count; index += 1) {
    if (index >= leftParts.length) return -1;
    if (index >= rightParts.length) return 1;
    const leftPart = leftParts[index];
    const rightPart = rightParts[index];
    const leftNumeric = /^\d+$/.test(leftPart);
    const rightNumeric = /^\d+$/.test(rightPart);
    if (leftNumeric && rightNumeric) {
      const result = Number(leftPart) - Number(rightPart);
      if (result) return result > 0 ? 1 : -1;
    } else if (leftNumeric !== rightNumeric) {
      return leftNumeric ? -1 : 1;
    } else if (leftPart !== rightPart) {
      return leftPart < rightPart ? -1 : 1;
    }
  }
  return 0;
}

function compareMacVersions(leftValue, rightValue) {
  const left = normalizedVersion(leftValue);
  const right = normalizedVersion(rightValue);
  if (!left || !right) return null;
  const [leftCore, leftPrerelease] = left.split("-", 2);
  const [rightCore, rightPrerelease] = right.split("-", 2);
  const leftNumbers = leftCore.split(".").map(Number);
  const rightNumbers = rightCore.split(".").map(Number);
  for (let index = 0; index < 3; index += 1) {
    if (leftNumbers[index] !== rightNumbers[index]) {
      return leftNumbers[index] > rightNumbers[index] ? 1 : -1;
    }
  }
  return comparePrerelease(leftPrerelease, rightPrerelease);
}

function compareMacReleaseCandidates(left, right) {
  const leftTag = parseMacReleaseTag(left?.releaseTag || left?.tag);
  const rightTag = parseMacReleaseTag(right?.releaseTag || right?.tag);
  if (!leftTag || !rightTag) return 0;
  const versionResult = compareMacVersions(leftTag.version, rightTag.version);
  if (versionResult) return versionResult;
  if (leftTag.prerelease !== rightTag.prerelease) return leftTag.prerelease ? -1 : 1;

  const leftBuild = Number(normalizedBuild(left?.build) || 0);
  const rightBuild = Number(normalizedBuild(right?.build) || 0);
  if (leftBuild !== rightBuild) return leftBuild > rightBuild ? 1 : -1;

  const leftTimestamp = leftTag.sourceTimestamp || 0;
  const rightTimestamp = rightTag.sourceTimestamp || 0;
  if (leftTimestamp !== rightTimestamp) return leftTimestamp > rightTimestamp ? 1 : -1;

  // A release list is not guaranteed to be returned in a stable order. The
  // tag is unique for timestamped prereleases, so use it as the final stable
  // tie-breaker for otherwise identical metadata.
  return leftTag.tag === rightTag.tag ? 0 : leftTag.tag > rightTag.tag ? 1 : -1;
}

function normalizedBuild(value) {
  const build = String(value ?? "").trim();
  if (!/^\d{1,10}$/.test(build)) return null;
  const numeric = Number(build);
  return Number.isSafeInteger(numeric) && numeric > 0 ? build : null;
}

function isMacUpdateAvailable({
  currentVersion,
  currentBuild,
  candidateVersion,
  candidateBuild,
} = {}) {
  const versionResult = compareMacVersions(candidateVersion, currentVersion);
  if (versionResult === null) return false;
  if (versionResult !== 0) return versionResult > 0;
  const current = normalizedBuild(currentBuild);
  const candidate = normalizedBuild(candidateBuild);
  if (!current || !candidate) return false;
  return Number(candidate) > Number(current);
}

function normalizedHost(value) {
  return String(value || "").trim().toLowerCase().replace(/\.$/, "");
}

function allowsMacUpdateURL(value, allowedHosts = MAC_UPDATE_HOSTS) {
  let url;
  try { url = value instanceof URL ? new URL(value.href) : new URL(String(value)); }
  catch { return false; }
  const host = normalizedHost(url.hostname);
  return url.protocol === "https:"
    && !url.username
    && !url.password
    && !url.hash
    && (!url.port || url.port === "443")
    && allowedHosts.has(host);
}

function macUpdateAllowedHosts(value) {
  let url;
  try { url = value instanceof URL ? new URL(value.href) : new URL(String(value)); }
  catch { return new Set(); }
  return normalizedHost(url.hostname) === "github.com"
    ? MAC_UPDATE_HOSTS
    : new Set([normalizedHost(url.hostname)]);
}

async function cancelBody(response) {
  try {
    const result = response?.body?.cancel?.();
    if (result && typeof result.then === "function") await result.catch(() => undefined);
  } catch {
    // The response is already being discarded.
  }
}

async function trustedFetch(requestURL, options = {}, {
  fetchImpl = fetch,
  maxRedirects = MAC_UPDATE_MAX_REDIRECTS,
  allowedHosts = macUpdateAllowedHosts(requestURL),
} = {}) {
  let current;
  try { current = new URL(String(requestURL)); }
  catch { throw new Error("The macOS update URL is invalid."); }
  if (!allowsMacUpdateURL(current, allowedHosts)) {
    throw new Error("The macOS update URL is not trusted.");
  }
  for (let redirectCount = 0; ; redirectCount += 1) {
    const response = await fetchImpl(current, { ...options, redirect: "manual" });
    if (![301, 302, 303, 307, 308].includes(response.status)) return response;
    const location = response.headers?.get?.("location");
    if (!location || redirectCount >= maxRedirects) {
      await cancelBody(response);
      throw new Error("The macOS update redirected too many times.");
    }
    let next;
    try { next = new URL(location, current); }
    catch {
      await cancelBody(response);
      throw new Error("The macOS update returned an invalid redirect.");
    }
    if (!allowsMacUpdateURL(next, allowedHosts)) {
      await cancelBody(response);
      throw new Error("The macOS update returned an untrusted redirect.");
    }
    await cancelBody(response);
    current = next;
  }
}

async function responseBytes(response, maximumBytes, label) {
  if (!response?.ok) {
    await cancelBody(response);
    throw new Error(`${label} returned HTTP ${response?.status || 0}.`);
  }
  return readResponseBytes(response, maximumBytes, label);
}

function normalizeMacUpdateManifest(value, { releaseTag } = {}) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("The macOS update manifest is invalid.");
  }
  const version = normalizedVersion(value.version);
  const build = normalizedBuild(value.build);
  const url = (() => {
    try { return new URL(String(value.url || "")); } catch { return null; }
  })();
  const sha256 = String(value.sha256 || "").trim().toLowerCase();
  if (!version || !build || !url || !allowsMacUpdateURL(url, new Set(["github.com"])) || !/^[a-f0-9]{64}$/.test(sha256)) {
    throw new Error("The macOS update manifest is invalid.");
  }
  const normalized = { version, build, url: url.href, sha256 };
  const requestedReleaseTag = releaseTag === undefined ? value.releaseTag : releaseTag;
  if (requestedReleaseTag !== undefined) {
    const parsedTag = parseMacReleaseTag(requestedReleaseTag);
    if (!parsedTag || parsedTag.version !== version) {
      throw new Error("The macOS update manifest has an invalid release tag.");
    }
    normalized.releaseTag = parsedTag.tag;
  }
  return Object.freeze(normalized);
}

async function fetchManifestAtURL(manifestURL, fetchImpl, releaseTag) {
  let url;
  try { url = new URL(String(manifestURL)); } catch { throw new Error("The macOS update manifest URL is invalid."); }
  if (!allowsMacUpdateURL(url, new Set(["github.com"]))) {
    throw new Error("The macOS update manifest URL is not trusted.");
  }
  const response = await trustedFetch(url, {
    headers: { Accept: "application/json", "Cache-Control": "no-cache" },
  }, { fetchImpl, allowedHosts: MAC_UPDATE_HOSTS });
  const raw = await responseBytes(response, MAC_UPDATE_MAX_MANIFEST_BYTES, "The macOS update manifest");
  let payload;
  try { payload = JSON.parse(raw.toString("utf8")); }
  catch { throw new Error("The macOS update manifest is not valid JSON."); }
  return normalizeMacUpdateManifest(payload, releaseTag === undefined ? {} : { releaseTag });
}

async function fetchMacReleaseList(fetchImpl = fetch) {
  const response = await trustedFetch(MAC_UPDATE_RELEASES_API_URL, {
    headers: {
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "Cache-Control": "no-cache",
    },
  }, { fetchImpl, allowedHosts: MAC_UPDATE_API_HOSTS });
  const raw = await responseBytes(response, MAC_UPDATE_MAX_RELEASE_LIST_BYTES, "The macOS release list");
  let releases;
  try { releases = JSON.parse(raw.toString("utf8")); }
  catch { throw new Error("The macOS release list is not valid JSON."); }
  if (!Array.isArray(releases)) throw new Error("The macOS release list is invalid.");
  return releases;
}

async function discoverMacUpdateManifest({ fetchImpl = fetch } = {}) {
  const releases = await fetchMacReleaseList(fetchImpl);
  const candidates = releases
    .filter((release) => release && !release.draft && Array.isArray(release.assets))
    .map((release) => ({ release, tag: parseMacReleaseTag(release.tag_name) }))
    .filter(({ release, tag }) => tag && Boolean(release.prerelease) === tag.prerelease)
    .sort((left, right) => compareMacReleaseCandidates(
      { releaseTag: right.tag.tag },
      { releaseTag: left.tag.tag },
    ));
  for (const { release, tag } of candidates) {
    const asset = release.assets.find((candidate) => candidate?.name === "latest-mac.json");
    const manifestURL = releaseAssetURL(asset?.browser_download_url, tag.tag, "latest-mac.json");
    if (!manifestURL) continue;
    try {
      const manifest = await fetchManifestAtURL(manifestURL, fetchImpl, tag.tag);
      if (manifest.version !== tag.version) continue;
      if (!releaseAssetURL(manifest.url, tag.tag, MAC_ARCHIVE_NAME)) continue;
      return Object.freeze({
        ...manifest,
        releaseTag: tag.tag,
        prerelease: tag.prerelease,
        sourceTimestamp: tag.sourceTimestamp,
      });
    } catch {
      // An incomplete or malformed release must not hide an older usable one.
    }
  }
  throw new Error("No published macOS release contains latest-mac.json.");
}

async function fetchMacUpdateManifest({
  manifestURL,
  fetchImpl = fetch,
} = {}) {
  const requested = String(manifestURL || "").trim();
  if (!requested) {
    return discoverMacUpdateManifest({ fetchImpl });
  }
  return fetchManifestAtURL(requested, fetchImpl);
}

function updateArchiveFilename(version, releaseTag) {
  const normalized = normalizedVersion(version);
  if (!normalized) throw new Error("The macOS update version is invalid.");
  const parsedTag = releaseTag ? parseMacReleaseTag(releaseTag) : null;
  if (parsedTag?.prerelease) return `Resonance-macOS-${normalized}-${parsedTag.sourceTimestamp}.zip`;
  return `Resonance-macOS-${normalized}.zip`;
}

async function sha256File(filePath) {
  const hash = createHash("sha256");
  const file = await fs.open(filePath, "r");
  try {
    while (true) {
      const { bytesRead, buffer } = await file.read({ buffer: Buffer.allocUnsafe(1024 * 1024) });
      if (!bytesRead) break;
      hash.update(buffer.subarray(0, bytesRead));
    }
  } finally {
    await file.close().catch(() => undefined);
  }
  return hash.digest("hex");
}

async function validateMacUpdateArchive(archivePath, manifest, {
  statImpl = fs.stat,
  hashImpl = sha256File,
} = {}) {
  const normalized = normalizeMacUpdateManifest(manifest);
  try {
    const information = await statImpl(archivePath);
    if (!information.isFile() || information.size <= 0 || information.size > MAC_UPDATE_MAX_ARCHIVE_BYTES) return false;
    const digest = await hashImpl(archivePath);
    return digest.toLowerCase() === normalized.sha256;
  } catch {
    return false;
  }
}

async function downloadMacUpdate({
  manifest,
  destinationDirectory,
  fetchImpl = fetch,
  onProgress = () => {},
} = {}) {
  const normalized = normalizeMacUpdateManifest(manifest);
  const response = await trustedFetch(normalized.url, {
    headers: { Accept: "application/zip", "Cache-Control": "no-cache" },
  }, { fetchImpl, allowedHosts: MAC_UPDATE_HOSTS });
  if (!response.ok || !response.body) {
    await cancelBody(response);
    throw new Error(`The macOS update archive returned HTTP ${response?.status || 0}.`);
  }
  const declared = Number(response.headers?.get?.("content-length") || 0);
  if (Number.isFinite(declared) && (declared <= 0 || declared > MAC_UPDATE_MAX_ARCHIVE_BYTES)) {
    await cancelBody(response);
    throw new Error("The macOS update archive is too large.");
  }
  await fs.mkdir(destinationDirectory, { recursive: true });
  const temporary = path.join(destinationDirectory, `.${updateArchiveFilename(normalized.version, normalized.releaseTag)}.${randomUUID()}.part`);
  const destination = path.join(destinationDirectory, updateArchiveFilename(normalized.version, normalized.releaseTag));
  const file = await fs.open(temporary, "wx");
  const hash = createHash("sha256");
  let received = 0;
  try {
    const reader = response.body.getReader();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      received += value.byteLength;
      if (received > MAC_UPDATE_MAX_ARCHIVE_BYTES || (declared > 0 && received > declared)) {
        await reader.cancel().catch(() => undefined);
        throw new Error("The macOS update archive is too large.");
      }
      const bytes = Buffer.from(value);
      hash.update(bytes);
      await file.write(bytes);
      onProgress({ completed: received, total: declared || null, percent: declared ? Math.round(received / declared * 100) : null });
    }
  } catch (error) {
    await fs.rm(temporary, { force: true }).catch(() => undefined);
    await file.close().catch(() => undefined);
    throw error;
  }
  await file.close();
  const digest = hash.digest("hex");
  if (!received || (declared > 0 && received !== declared) || digest !== normalized.sha256) {
    await fs.rm(temporary, { force: true }).catch(() => undefined);
    throw new Error("The macOS update checksum did not match the release manifest.");
  }
  await fs.rm(destination, { force: true });
  await fs.rename(temporary, destination);
  return Object.freeze({ path: destination, bytes: received, sha256: digest });
}

async function launchMacUpdateInstaller({
  archivePath,
  destinationPath,
  version,
  helperPath,
  processID = process.pid,
  spawnImpl = spawn,
  fsImpl = fs,
  environment = process.env,
  allowDevelopmentUpdates = false,
  authorizeInstall = () => true,
} = {}) {
  const normalized = normalizedVersion(version);
  if (!normalized || !archivePath || !destinationPath || !helperPath) return false;
  let helper = null;
  try {
    const directory = await fsImpl.mkdtemp(path.join(require("node:os").tmpdir(), "resonance-update-"));
    helper = path.join(directory, "install-update.sh");
    if (!authorizeInstall()) throw new Error("The macOS update channel changed.");
    await fsImpl.copyFile(helperPath, helper);
    if (!authorizeInstall()) throw new Error("The macOS update channel changed.");
    await fsImpl.chmod(helper, 0o700);
    if (!authorizeInstall()) throw new Error("The macOS update channel changed.");
    const childEnvironment = { ...environment };
    // Development builds carry an explicit updater policy in their bundle.
    // Translate that policy into the helper's narrowly scoped opt-in instead
    // of requiring users to launch the app with a hidden environment flag.
    if (allowDevelopmentUpdates) childEnvironment.RESONANCE_ALLOW_UNVERIFIED_UPDATES = "1";
    else delete childEnvironment.RESONANCE_ALLOW_UNVERIFIED_UPDATES;
    const child = spawnImpl("/bin/bash", [helper, archivePath, destinationPath, String(processID), normalized], {
      detached: true,
      stdio: "ignore",
      env: childEnvironment,
    });
    child.unref?.();
    return true;
  } catch {
    if (helper) await fsImpl.rm(helper, { force: true }).catch(() => undefined);
    return false;
  }
}

module.exports = {
  MAC_UPDATE_HOSTS,
  MAC_UPDATE_RELEASES_API_URL,
  MAC_UPDATE_MANIFEST_URL,
  MAC_UPDATE_MAX_ARCHIVE_BYTES,
  MAC_UPDATE_MAX_MANIFEST_BYTES,
  MAC_UPDATE_MAX_RELEASE_LIST_BYTES,
  allowsMacUpdateURL,
  compareMacVersions,
  compareMacReleaseCandidates,
  downloadMacUpdate,
  discoverMacUpdateManifest,
  fetchMacUpdateManifest,
  fetchMacReleaseList,
  isMacUpdateAvailable,
  launchMacUpdateInstaller,
  normalizeMacUpdateManifest,
  normalizedBuild,
  normalizedVersion,
  parseMacReleaseTag,
  sha256File,
  trustedFetch,
  updateArchiveFilename,
  validateMacUpdateArchive,
};
