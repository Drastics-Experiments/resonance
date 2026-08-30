import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { mkdtemp, mkdir, rm, writeFile, chmod } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { promisify } from "node:util";
import { inflateRawSync } from "node:zlib";
import {
  SOURCE_PROJECT,
  SOURCE_TARGET,
  createSourceSnapshot,
  sourceExportPathAllowed,
} from "../ui/source-export.mjs";

const execFileAsync = promisify(execFile);

function zipEntries(archive) {
  const entries = new Map();
  let offset = 0;
  while (archive.readUInt32LE(offset) === 0x04034b50) {
    const method = archive.readUInt16LE(offset + 8);
    const compressedSize = archive.readUInt32LE(offset + 18);
    const size = archive.readUInt32LE(offset + 22);
    const nameLength = archive.readUInt16LE(offset + 26);
    const extraLength = archive.readUInt16LE(offset + 28);
    const name = archive.subarray(offset + 30, offset + 30 + nameLength).toString("utf8");
    const dataStart = offset + 30 + nameLength + extraLength;
    const compressed = archive.subarray(dataStart, dataStart + compressedSize);
    const contents = method === 8 ? inflateRawSync(compressed) : Buffer.from(compressed);
    assert.equal(contents.length, size);
    entries.set(name, { contents, mode: null });
    offset = dataStart + compressedSize;
  }
  while (archive.readUInt32LE(offset) === 0x02014b50) {
    const nameLength = archive.readUInt16LE(offset + 28);
    const extraLength = archive.readUInt16LE(offset + 30);
    const commentLength = archive.readUInt16LE(offset + 32);
    const name = archive.subarray(offset + 46, offset + 46 + nameLength).toString("utf8");
    entries.get(name).mode = archive.readUInt32LE(offset + 38) >>> 16;
    offset += 46 + nameLength + extraLength + commentLength;
  }
  assert.equal(archive.readUInt32LE(offset), 0x06054b50);
  return entries;
}

async function writeFixture(root, relativePath, contents) {
  const destination = path.join(root, ...relativePath.split("/"));
  await mkdir(path.dirname(destination), { recursive: true });
  await writeFile(destination, contents);
  return destination;
}

test("source export path policy rejects secrets, app data, dependencies, and build output", () => {
  for (const relativePath of [
    ".env",
    ".envfoo",
    ".env.local/secret",
    "windows/.env.local",
    ".git/config",
    "windows/node_modules/electron/index.js",
    "local-projects/private-app/source.js",
    "android/app/build/output.apk",
    "installers/macos/dist/Resonance.app",
    "Library.json",
    "state/server-credentials.json",
    "credentials/access-token.txt",
    "signing/notarization-profile.txt",
    "signing/distribution.p12",
    "Local Music/song.flac",
    "diagnostics/preview.log",
    "logs/state.json",
    "user data/state.json",
    ".ssh/id_rsa",
    "keys/release.gpg",
    "Application Support/Resonance/library.json",
    "../outside.txt",
    "/absolute/path.txt",
    "C:/absolute/path.txt",
    "scratch/access-token.txt",
    "scratch/admin-key.txt",
  ]) {
    assert.equal(sourceExportPathAllowed(relativePath), false, relativePath);
  }
  for (const relativePath of [
    "windows/package.json",
    "windows/pnpm-lock.yaml",
    "mac/electron-builder.yml",
    "ios/Resonance/MusicLibrary.swift",
    "android/app/src/main/java/example/CredentialStore.kt",
  ]) {
    assert.equal(sourceExportPathAllowed(relativePath), true, relativePath);
  }
});

test("source snapshot captures the working tree and emits a verifiable buildable ZIP", async (t) => {
  const root = await mkdtemp(path.join(tmpdir(), "resonance-source-export-"));
  t.after(() => rm(root, { recursive: true, force: true }));

  await execFileAsync("git", ["init", "-b", "preview-test"], { cwd: root });
  await writeFixture(root, ".launcher-terminal.zsh", "#!/bin/zsh\nres_launch_macos() { :; }\n");
  await writeFixture(root, "README.md", "committed\n");
  await writeFixture(root, "windows/package.json", "{\"private\":true}\n");
  await writeFixture(root, "windows/pnpm-lock.yaml", "lockfileVersion: '9.0'\n");
  await writeFixture(root, "windows/.npmrc", "node-linker=hoisted\n");
  await writeFixture(root, "mac/electron-builder.yml", "appId: example.preview\n");
  await writeFixture(root, "mac/scripts/build-electron.sh", "#!/bin/sh\nexit 0\n");
  const executable = await writeFixture(root, "scripts/build.sh", "#!/bin/sh\nexit 0\n");
  await chmod(executable, 0o755);
  await writeFixture(root, ".env.production", "SECRET=do-not-export\n");
  await writeFixture(root, "state/server-credentials.json", "{\"token\":\"do-not-export\"}\n");
  await writeFixture(root, "windows/node_modules/private/index.js", "do not export\n");
  await writeFixture(root, "installers/macos/dist/build.txt", "do not export\n");
  await writeFixture(root, "signing/distribution.p12", "do not export\n");
  await writeFixture(root, "private/.npmrc", "//registry.example.invalid/:_authToken=do-not-export\n");
  await writeFixture(root, "scratch.txt", "Authorization: Bearer ghp_012345678901234567890123456789012345\n");
  await writeFixture(root, "notes.txt", "admin_key = \"tailnet-preview-admin-key-value\"\n");
  await writeFixture(root, "certificate.txt", "-----BEGIN PRIVATE KEY-----\ndo-not-export\n-----END PRIVATE KEY-----\n");
  await writeFixture(root, "windows/auth-helper.mjs", "export const header = (token) => `Bearer ${token}`;\n");
  await writeFixture(root, "Local Music/song.flac", "do not export\n");
  await execFileAsync("git", ["add", "-f", "."], { cwd: root });
  await execFileAsync("git", ["update-index", "--chmod=+x", "scripts/build.sh"], { cwd: root });
  await execFileAsync("git", [
    "-c", "user.name=Preview Test",
    "-c", "user.email=preview@example.invalid",
    "commit", "-m", "fixture",
  ], { cwd: root });

  await writeFixture(root, "README.md", "working tree\n");
  await writeFixture(root, "windows/new-source.mjs", "export const current = true;\n");
  const now = Date.parse("2026-08-30T12:00:00.000Z");
  const snapshot = await createSourceSnapshot({ repoRoot: root, now: () => now, ttlMs: 60_000 });

  assert.deepEqual(Object.keys(snapshot.manifest), [
    "schemaVersion",
    "project",
    "target",
    "revision",
    "source",
    "createdAt",
    "expiresAt",
  ]);
  assert.deepEqual(Object.keys(snapshot.manifest.revision), ["branch", "commit", "dirty", "label"]);
  assert.deepEqual(Object.keys(snapshot.manifest.source), ["url", "format", "sha256", "size"]);
  assert.equal(snapshot.manifest.schemaVersion, 1);
  assert.equal(snapshot.manifest.project, SOURCE_PROJECT);
  assert.equal(snapshot.manifest.target, SOURCE_TARGET);
  assert.equal(snapshot.manifest.revision.branch, "preview-test");
  assert.match(snapshot.manifest.revision.commit, /^[0-9a-f]{40}$/);
  assert.equal(snapshot.manifest.revision.dirty, true);
  assert.match(snapshot.manifest.revision.label, /^preview-test @ [0-9a-f]{7} \+ changes$/);
  assert.equal(snapshot.manifest.source.format, "zip");
  assert.equal(snapshot.manifest.source.size, snapshot.archive.length);
  assert.ok(snapshot.manifest.source.size <= 256 * 1024 * 1024);
  assert.equal(snapshot.manifest.source.sha256, createHash("sha256").update(snapshot.archive).digest("hex"));
  assert.equal(
    snapshot.manifest.source.url,
    `/__resonance/preview/v1/source/${snapshot.manifest.source.sha256}.zip`,
  );
  assert.equal(snapshot.manifest.createdAt, "2026-08-30T12:00:00.000Z");
  assert.equal(snapshot.manifest.expiresAt, "2026-08-30T12:01:00.000Z");

  const entries = zipEntries(snapshot.archive);
  for (const entryPath of entries.keys()) {
    assert.equal(entryPath.startsWith("/"), false, entryPath);
    assert.equal(entryPath.includes("\\"), false, entryPath);
    assert.equal(entryPath.split("/").some((component) => component === "." || component === ".."), false, entryPath);
  }
  assert.equal(entries.get(".launcher-terminal.zsh").contents.toString(), "#!/bin/zsh\nres_launch_macos() { :; }\n");
  assert.ok(entries.has("windows/package.json"));
  assert.ok(entries.has("windows/pnpm-lock.yaml"));
  assert.equal(entries.get("README.md").contents.toString(), "working tree\n");
  assert.equal(entries.get("windows/new-source.mjs").contents.toString(), "export const current = true;\n");
  assert.equal(entries.get("windows/auth-helper.mjs").contents.toString(), "export const header = (token) => `Bearer ${token}`;\n");
  assert.equal(entries.get("windows/.npmrc").contents.toString(), "node-linker=hoisted\n");
  assert.equal(entries.get("mac/electron-builder.yml").contents.toString(), "appId: example.preview\n");
  assert.equal(entries.get("scripts/build.sh").mode & 0o111, 0o111);
  for (const excluded of [
    ".env.production",
    "state/server-credentials.json",
    "windows/node_modules/private/index.js",
    "installers/macos/dist/build.txt",
    "signing/distribution.p12",
    "private/.npmrc",
    "scratch.txt",
    "notes.txt",
    "certificate.txt",
    "Local Music/song.flac",
  ]) {
    assert.equal(entries.has(excluded), false, excluded);
  }
});
