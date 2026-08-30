import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import clientConfig from "../client-config.cjs";
import macMigration from "../mac-app-migration.cjs";

const windowsRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const packageJSON = JSON.parse(await readFile(path.join(windowsRoot, "package.json"), "utf8"));
const { clientConfigRequestContext } = clientConfig;
const {
  MAC_DEFAULT_KEYS,
  MAC_MIGRATION_ID,
  migrateMacNativeData,
  nativeMacState,
} = macMigration;

test("shared Electron sources retain the Windows target and macOS release contract", async () => {
  assert.equal(packageJSON.main, "main.cjs");
  assert.equal(packageJSON.build?.asar, true);
  assert.ok(packageJSON.build?.win, "the shared package must retain a Windows target");

  const files = Array.isArray(packageJSON.build.files) ? packageJSON.build.files : [];
  assert.ok(files.some((entry) => String(entry) === "main.cjs"));
  assert.ok(files.some((entry) => String(entry) === "preload.cjs"));
  assert.ok(files.some((entry) => String(entry) === "mac-app-migration.cjs"));
  assert.ok(files.some((entry) => String(entry).startsWith("ui/")), "the renderer must be in the packaged closure");

  const [macConfig, macBuildScript, macReadme, windowsReadme] = await Promise.all([
    readFile(path.resolve(windowsRoot, "../mac/electron-builder.yml"), "utf8"),
    readFile(path.resolve(windowsRoot, "../mac/scripts/build-electron.sh"), "utf8"),
    readFile(path.resolve(windowsRoot, "../installers/macos/README.md"), "utf8"),
    readFile(path.join(windowsRoot, "README.md"), "utf8"),
  ]);
  assert.match(macConfig, /appId:\s*com\.gavindietrich\.LikedSongsFocus/);
  assert.match(macConfig, /directories:\s*[\s\S]*output:\s*\.\.\/installers\/macos\/dist/);
  assert.match(macConfig, /target:\s*[\s\S]*- zip[\s\S]*- pkg/);
  assert.match(macConfig, /!test\{,\/\*\*\}/, "macOS packages must not include test fixtures");
  assert.match(macBuildScript, /electron-builder/);
  assert.match(macBuildScript, /--mac/);
  assert.match(macBuildScript, /WINDOWS_DIR/);
  assert.match(
    macBuildScript,
    /MAC_UPDATE_AUTHENTICITY[\s\S]*development[\s\S]*unset CSC_LINK[\s\S]*unset CSC_INSTALLER_LINK/,
    "development packaging must not pass blank certificate paths to electron-builder",
  );
  assert.match(
    macBuildScript,
    /if \[\[ "\$MAC_UPDATE_AUTHENTICITY" == "development" \]\]; then[\s\S]*export CSC_FOR_PULL_REQUEST=true/,
    "development packaging must allow ad-hoc signing on CI pull requests",
  );
  assert.doesNotMatch(macBuildScript, /swift\s+(build|run|test)/i);
  assert.match(`${macReadme}\n${windowsReadme}`, /Electron/i);
  assert.match(macReadme, /Resonance-macOS\.zip/);
  assert.match(macReadme, /Resonance-Installer\.pkg/);
});

test("shared desktop client-config audiences distinguish Windows and macOS explicitly", () => {
  const base = {
    origin: "https://music.example.test/library",
    profileID: "listener-a",
    appVersion: "2.0.0",
    appBuild: 17,
    cohortKey: "ABEiM0RVZneImaq7zN3u_w",
  };
  const windows = clientConfigRequestContext({ ...base, platform: "windows" });
  const macos = clientConfigRequestContext({ ...base, platform: "macos" });
  assert.equal(windows.platform, "windows");
  assert.equal(macos.platform, "macos");
  assert.equal(windows.request_headers["X-Resonance-Client-Platform"], "windows");
  assert.equal(macos.request_headers["X-Resonance-Client-Platform"], "macos");
  assert.equal(windows.cohort_bucket, macos.cohort_bucket);
});

async function filesUnder(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await filesUnder(absolute));
    else files.push(absolute);
  }
  return files;
}

test("macOS no longer retains a native Swift app target", async () => {
  const macRoot = path.resolve(windowsRoot, "../mac");
  const files = await filesUnder(macRoot);
  const nativeSwiftFiles = files.filter((file) => {
    const relative = path.relative(macRoot, file);
    return relative === "Package.swift"
      || relative.startsWith(`Sources${path.sep}`)
      || relative.startsWith(`Tests${path.sep}`);
  });
  assert.deepEqual(nativeSwiftFiles, [], "macOS app code must be shared Electron, not the retired Swift target");
  const workflow = await readFile(path.resolve(windowsRoot, "../.github/workflows/macos.yml"), "utf8");
  assert.doesNotMatch(workflow, /swift\s+(build|run|test)|swift package|mac\/(?:Package|Sources|Tests)/i);
});

test("the shared renderer requires Electron and has no browser fixture bridge", async () => {
  const [renderer, html, preload] = await Promise.all([
    readFile(path.join(windowsRoot, "ui/app.js"), "utf8"),
    readFile(path.join(windowsRoot, "ui/index.html"), "utf8"),
    readFile(path.join(windowsRoot, "preload.cjs"), "utf8"),
  ]);
  assert.match(renderer, /from \"\.\/core\.js\"/);
  assert.match(renderer, /requires the Electron preload bridge/);
  assert.doesNotMatch(renderer, /api\["browser"\]|resetBrowserState/);
  assert.doesNotMatch(html, /browser-runtime\.js|browserPreviewBar|Reset demo/);
  assert.match(preload, /contextBridge\.exposeInMainWorld\("resonance"/);
});

function encodedJSON(value) {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64");
}

test("native macOS state migration preserves local media, playlists, and dated history", () => {
  const state = nativeMacState({
    [MAC_DEFAULT_KEYS.library]: encodedJSON({
      tracks: [{
        id: "native-track",
        title: "Migrated Song",
        artist: "Native Artist",
        album: "Native Album",
        duration: 123,
        fileURL: "file:///Users/listener/Music/Migrated%20Song.mp3",
        dateAdded: 0,
      }],
      favorites: ["native-track"],
      playlists: [{ id: "native-playlist", name: "Road Trip", trackIDs: ["native-track"], isSystem: false }],
      playlistRevision: 8,
    }),
    [MAC_DEFAULT_KEYS.serverURL]: "https://music.example.test",
    [MAC_DEFAULT_KEYS.currentTrack]: "native-track",
    [MAC_DEFAULT_KEYS.position]: 17.5,
    [MAC_DEFAULT_KEYS.playbackContext]: encodedJSON(["native-track"]),
    [MAC_DEFAULT_KEYS.shuffleQueue]: encodedJSON(["native-track"]),
    [MAC_DEFAULT_KEYS.listeningHistory]: encodedJSON([{
      id: "history-entry",
      trackID: "native-track",
      startedAt: 0,
      listenedSeconds: 22,
    }]),
  });

  assert.equal(state.tracks.length, 1);
  assert.equal(state.tracks[0].filePath, "/Users/listener/Music/Migrated Song.mp3");
  assert.equal(state.tracks[0].available, true, "migration keeps an external local path even before Electron stats it");
  assert.deepEqual(state.favorites, ["native-track"]);
  assert.deepEqual(state.playlists[0].trackIDs, ["native-track"]);
  assert.equal(state.serverURL, "https://music.example.test");
  assert.equal(state.currentTrackID, "native-track");
  assert.equal(state.position, 17.5);
  assert.equal(state.listeningHistory[0].startedAt, "2001-01-01T00:00:00.000Z");
  assert.ok(state.completedMigrations.includes(MAC_MIGRATION_ID));
});

test("macOS migration moves app-owned support data without overwriting Electron data", async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "resonance-mac-migration-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const homeDirectory = path.join(root, "home");
  const targetUserData = path.join(root, "electron-user-data");
  const legacySupport = path.join(homeDirectory, "Library", "Application Support", "Liked Songs");
  const nativeSupport = path.join(homeDirectory, "Library", "Application Support", "Resonance");
  const externalMusic = path.join(root, "Music", "Migrated Song.mp3");
  await mkdir(legacySupport, { recursive: true });
  await mkdir(nativeSupport, { recursive: true });
  await mkdir(path.dirname(externalMusic), { recursive: true });
  await writeFile(path.join(legacySupport, "artwork.bin"), "native-artwork");
  await writeFile(externalMusic, "audio-bytes");
  await writeFile(
    path.join(nativeSupport, "server-credentials.json"),
    JSON.stringify({ values: {
      "music-server-client-token": "test-client-token",
      "music-server-admin-token": "test-admin-token",
      "music-server-account-session-v1": JSON.stringify({ session: "test-session" }),
    } }),
  );

  const defaults = {
    [MAC_DEFAULT_KEYS.library]: encodedJSON({
      tracks: [{
        id: "native-track",
        title: "Migrated Song",
        artist: "Native Artist",
        filePath: externalMusic,
      }],
    }),
  };
  const defaultsSnapshot = { ...defaults };
  const result = await migrateMacNativeData({
    homeDirectory,
    targetUserData,
    platform: "darwin",
    defaults,
  });

  assert.equal(result.migrated, true);
  assert.equal(result.state.tracks[0].filePath, externalMusic);
  assert.equal(result.credentials.clientToken, "test-client-token");
  assert.equal(result.credentials.adminToken, "test-admin-token");
  assert.deepEqual(result.accountSession, { session: "test-session" });
  assert.equal(result.credentialValues["music-server-client-token"], "test-client-token");
  assert.deepEqual(defaults, defaultsSnapshot, "migration must not mutate the native preferences snapshot");
  assert.equal(await stat(path.join(targetUserData, "artwork.bin")).then(() => true), true);
  await assert.rejects(stat(legacySupport), /ENOENT/);
  assert.equal(await readFile(path.join(targetUserData, "artwork.bin"), "utf8"), "native-artwork");
});

test("macOS migration keeps destination files and recovers conflicting native files", async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "resonance-mac-migration-conflict-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const homeDirectory = path.join(root, "home");
  const targetUserData = path.join(root, "electron-user-data");
  const legacySupport = path.join(homeDirectory, "Library", "Application Support", "Liked Songs");
  await mkdir(legacySupport, { recursive: true });
  await mkdir(targetUserData, { recursive: true });
  await writeFile(path.join(legacySupport, "library.json"), "native-version");
  await writeFile(path.join(targetUserData, "library.json"), "electron-version");

  const result = await migrateMacNativeData({
    homeDirectory,
    targetUserData,
    platform: "darwin",
    defaults: {},
  });

  assert.equal(result.supportMigrations[0].conflicts, 1);
  assert.equal(await readFile(path.join(targetUserData, "library.json"), "utf8"), "electron-version");
  assert.equal(await readFile(path.join(targetUserData, "Legacy Recovery", "library.json"), "utf8"), "native-version");
  await assert.rejects(stat(legacySupport), /ENOENT/);
});
