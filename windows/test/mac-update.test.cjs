const assert = require("node:assert/strict");
const { createHash } = require("node:crypto");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const {
  allowsMacUpdateURL,
  compareMacVersions,
  downloadMacUpdate,
  fetchMacUpdateManifest,
  isMacUpdateAvailable,
  normalizeMacUpdateManifest,
  updateArchiveFilename,
  validateMacUpdateArchive,
} = require("../mac-update.cjs");

const ARCHIVE = Buffer.from("a complete macOS update archive for tests", "utf8");
const SHA256 = createHash("sha256").update(ARCHIVE).digest("hex");
const MANIFEST = {
  version: "1.2.3",
  build: "18",
  url: "https://github.com/Drastics-Experiments/resonance/releases/download/v1.2.3/Resonance-macOS.zip",
  sha256: SHA256,
};

function response(body, headers = {}, status = 200) {
  return new Response(body, { status, headers: { "content-length": String(body?.byteLength || body?.length || 0), ...headers } });
}

test("compares macOS release versions and build numbers", () => {
  assert.equal(compareMacVersions("v1.2.3", "1.2.3"), 0);
  assert.equal(compareMacVersions("1.2.4", "1.2.3"), 1);
  assert.equal(compareMacVersions("1.2.3-beta.2", "1.2.3-beta.10"), -1);
  assert.equal(compareMacVersions("1.2.3", "1.2.3-rc.1"), 1);
  assert.equal(isMacUpdateAvailable({ currentVersion: "1.2.3", currentBuild: 17, candidateVersion: "1.2.3", candidateBuild: "18" }), true);
  assert.equal(isMacUpdateAvailable({ currentVersion: "1.2.3", currentBuild: 18, candidateVersion: "1.2.3", candidateBuild: "18" }), false);
});

test("keeps macOS update URLs on the GitHub release host allowlist", () => {
  assert.equal(allowsMacUpdateURL(MANIFEST.url, new Set(["github.com"])), true);
  assert.equal(allowsMacUpdateURL("http://github.com/release.zip", new Set(["github.com"])), false);
  assert.equal(allowsMacUpdateURL("https://github.com.evil.example/release.zip", new Set(["github.com"])), false);
  assert.equal(allowsMacUpdateURL("https://github.com/release.zip#fragment", new Set(["github.com"])), false);
  assert.throws(() => normalizeMacUpdateManifest({ ...MANIFEST, url: "https://objects.githubusercontent.com/release.zip" }), /manifest is invalid/i);
});

test("fetches a bounded manifest and rejects foreign redirects", async () => {
  const manifestResponse = response(JSON.stringify(MANIFEST), { "content-type": "application/json" });
  const manifest = await fetchMacUpdateManifest({
    manifestURL: "https://github.com/Drastics-Experiments/resonance/releases/latest/download/latest-mac.json",
    fetchImpl: async () => manifestResponse,
  });
  assert.deepEqual(manifest, { ...MANIFEST, url: MANIFEST.url });

  await assert.rejects(fetchMacUpdateManifest({
    fetchImpl: async () => new Response(null, {
      status: 302,
      headers: { location: "https://evil.example/latest-mac.json" },
    }),
  }), /untrusted redirect/i);
});

test("downloads, verifies, and validates the macOS archive", async (t) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "resonance-mac-update-test-"));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const progress = [];
  const downloaded = await downloadMacUpdate({
    manifest: MANIFEST,
    destinationDirectory: directory,
    fetchImpl: async () => response(ARCHIVE, { "content-type": "application/zip" }),
    onProgress: (value) => progress.push(value),
  });
  assert.equal(path.basename(downloaded.path), updateArchiveFilename(MANIFEST.version));
  assert.deepEqual(await fs.readFile(downloaded.path), ARCHIVE);
  assert.equal(await validateMacUpdateArchive(downloaded.path, MANIFEST), true);
  assert.ok(progress.at(-1).percent === 100);

  await fs.appendFile(downloaded.path, Buffer.from("tamper"));
  assert.equal(await validateMacUpdateArchive(downloaded.path, MANIFEST), false);
});
