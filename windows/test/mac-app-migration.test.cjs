"use strict";

const assert = require("node:assert/strict");
const { createHash } = require("node:crypto");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const {
  FILE_CREDENTIAL_KEYS,
  MAC_DEFAULT_KEYS,
  MAC_MIGRATION_ID,
  MAC_NATIVE_BUNDLE_IDENTIFIER,
  cleanupMacNativeData,
  electronCredentialDocument,
  mergeNativeDirectory,
  mergeMacNativeState,
  migrateMacNativeData,
  nativeCredentialDocument,
  nativeMacPaths,
  nativeMacState,
} = require("../mac-app-migration.cjs");

function encoded(value) {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64");
}

test("native macOS defaults become Electron state without losing media metadata", () => {
  const trackID = "12345678-1234-1234-1234-123456789abc";
  const library = {
    tracks: [{
      id: trackID,
      title: "Native Video",
      artist: "Resonance",
      album: "Migration",
      duration: 123,
      kind: "Video",
      artwork: 1,
      artworkData: Buffer.from([0xff, 0xd8, 0xff, 0x00]).toString("base64"),
      artworkURL: "https://example.com/art.jpg",
      fileURL: "file:///Users/test/Music/native.mp4",
      remoteID: "remote-song",
      sourceServer: "https://music.example/library",
      syncProfileID: "profile-a",
      sourceURL: "https://www.youtube.com/watch?v=abc",
      dateAdded: 0,
    }],
    playlists: [{ id: "playlist-a", name: "Road trip", trackIDs: [trackID], isSystem: false }],
    favorites: [trackID],
    syncProfileID: "profile-a",
    syncProfileName: "Personal",
    playlistRevision: 3,
    completedMigrations: ["older-migration"],
  };
  const defaults = {
    [MAC_DEFAULT_KEYS.library]: encoded(library),
    [MAC_DEFAULT_KEYS.serverURL]: "https://music.example/library",
    [MAC_DEFAULT_KEYS.volume]: 0.5,
    [MAC_DEFAULT_KEYS.shuffle]: true,
    [MAC_DEFAULT_KEYS.currentTrack]: trackID,
    [MAC_DEFAULT_KEYS.playbackContext]: encoded([trackID]),
    [MAC_DEFAULT_KEYS.shuffleQueue]: encoded([trackID]),
    [MAC_DEFAULT_KEYS.listeningHistory]: encoded([{
      id: "history-a",
      trackID,
      startedAt: 0,
      listenedSeconds: 30,
      syncProfileID: "profile-a",
      remoteSongID: "remote-song",
    }]),
  };

  const state = nativeMacState(defaults);
  assert.equal(state.tracks.length, 1);
  assert.equal(state.tracks[0].kind, "video");
  assert.equal(state.tracks[0].mediaKind, "video");
  assert.equal(state.tracks[0].filePath, "/Users/test/Music/native.mp4");
  assert.match(state.tracks[0].artwork, /^data:image\/jpeg;base64,/);
  assert.equal(state.tracks[0].sourceSha256, null);
  assert.equal(state.playlists[0].name, "Road trip");
  assert.deepEqual(state.syncProfiles, [{ id: "profile-a", name: "Personal", is_default: true }]);
  assert.equal(state.currentTrackID, trackID);
  assert.deepEqual(state.playbackSourceQueueIDs, [trackID]);
  assert.equal(state.listeningHistory[0].profileID, "profile-a");
  assert.equal(state.listeningHistory[0].startedAt, "2001-01-01T00:00:00.000Z");
  assert.ok(state.completedMigrations.includes("older-migration"));
  assert.ok(state.completedMigrations.includes(MAC_MIGRATION_ID));
});

test("native plist string arrays restore playback context and shuffle queue", () => {
  const trackID = "native-track";
  const state = nativeMacState({
    [MAC_DEFAULT_KEYS.library]: encoded({
      tracks: [{ id: trackID, title: "Native track", filePath: "/Users/test/Music/native.mp3" }],
    }),
    [MAC_DEFAULT_KEYS.currentTrack]: trackID,
    // plutil emits these UserDefaults values as arrays, not JSON data blobs.
    [MAC_DEFAULT_KEYS.playbackContext]: [trackID, "missing-track"],
    [MAC_DEFAULT_KEYS.shuffleQueue]: [trackID, "missing-track"],
  });

  assert.deepEqual(state.playbackSourceQueueIDs, [trackID, "missing-track"]);
  assert.deepEqual(state.playbackQueueIDs, [trackID, "missing-track"]);
});

test("native current-context transfer modes migrate into Electron preferences", () => {
  const serverOrigin = "https://music.example.test";
  const profileID = "profile-a";
  const scope = createHash("sha256")
    .update(`${serverOrigin}\u0000${profileID}`)
    .digest("hex");
  const state = nativeMacState({
    [MAC_DEFAULT_KEYS.library]: encoded({
      syncProfileID: profileID,
      syncProfileName: "Personal",
    }),
    [MAC_DEFAULT_KEYS.serverURL]: `${serverOrigin}/library`,
    [`${MAC_DEFAULT_KEYS.transferModeUploadPrefix}${scope}`]: "server_source_link",
    [`${MAC_DEFAULT_KEYS.transferModeDownloadPrefix}${scope}`]: "stream_only",
  });

  assert.deepEqual(state.serverTransferPreferences, {
    [`${serverOrigin}#profile=${profileID}`]: {
      uploadMode: "server_source_link",
      downloadMode: "stream_only",
    },
  });
});

test("legacy production transfer modes migrate to the current production origin", () => {
  const legacyOrigin = "https://music.unblocked.mov";
  const currentOrigin = "https://resonance-core.blithe-haven-9710.chatgpt.site";
  const profileID = "profile-a";
  const scope = createHash("sha256")
    .update(`${legacyOrigin}\u0000${profileID}`)
    .digest("hex");
  const state = nativeMacState({
    [MAC_DEFAULT_KEYS.library]: encoded({ syncProfileID: profileID }),
    [MAC_DEFAULT_KEYS.serverURL]: `${legacyOrigin}/library`,
    [`${MAC_DEFAULT_KEYS.transferModeUploadPrefix}${scope}`]: "server_source_link",
    [`${MAC_DEFAULT_KEYS.transferModeDownloadPrefix}${scope}`]: "stream_only",
  });

  assert.deepEqual(state.serverTransferPreferences, {
    [`${currentOrigin}#profile=${profileID}`]: {
      uploadMode: "server_source_link",
      downloadMode: "stream_only",
    },
  });
});

test("macOS credential migration reads keyed native values and writes the same private shape", () => {
  const accountSession = { accessToken: "access", refreshToken: "refresh", email: "user@example.com" };
  const document = nativeCredentialDocument({ values: {
    [FILE_CREDENTIAL_KEYS.clientToken]: "client",
    [FILE_CREDENTIAL_KEYS.adminToken]: "admin",
    [FILE_CREDENTIAL_KEYS.accountSession]: JSON.stringify(accountSession),
    "future-key": "preserved-by-caller",
  } });
  assert.equal(document.clientToken, "client");
  assert.equal(document.adminToken, "admin");
  assert.deepEqual(document.accountSession, accountSession);
  const written = electronCredentialDocument({
    clientToken: document.clientToken,
    adminToken: document.adminToken,
    accountSession: document.accountSession,
    extraValues: { "future-key": "preserved-by-caller" },
  });
  assert.deepEqual(written, { values: {
    "future-key": "preserved-by-caller",
    [FILE_CREDENTIAL_KEYS.clientToken]: "client",
    [FILE_CREDENTIAL_KEYS.adminToken]: "admin",
    [FILE_CREDENTIAL_KEYS.accountSession]: JSON.stringify(accountSession),
  } });
});

test("native support conflicts are retained under Legacy Recovery", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "resonance-mac-migration-test-"));
  try {
    const source = path.join(root, "Liked Songs");
    const destination = path.join(root, "Resonance");
    await fs.mkdir(source, { recursive: true });
    await fs.mkdir(destination, { recursive: true });
    await fs.writeFile(path.join(source, "native-only.json"), "native");
    await fs.writeFile(path.join(source, "conflict.json"), "old");
    await fs.writeFile(path.join(destination, "conflict.json"), "new");
    await fs.writeFile(path.join(source, "same.json"), "same");
    await fs.writeFile(path.join(destination, "same.json"), "same");

    const result = await mergeNativeDirectory(source, destination);
    assert.equal(result.moved, true);
    assert.equal(result.conflicts, 1);
    assert.equal(await fs.readFile(path.join(destination, "native-only.json"), "utf8"), "native");
    assert.equal(await fs.readFile(path.join(destination, "Legacy Recovery", "conflict.json"), "utf8"), "old");
    assert.equal(await fs.readFile(path.join(destination, "conflict.json"), "utf8"), "new");
    await assert.rejects(fs.access(source));
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("source previews copy native support without removing production data", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "resonance-mac-preview-migration-test-"));
  try {
    const homeDirectory = path.join(root, "home");
    const nativeSupport = path.join(homeDirectory, "Library", "Application Support", "Resonance");
    const targetUserData = path.join(root, "preview-user-data");
    await fs.mkdir(nativeSupport, { recursive: true });
    await fs.writeFile(path.join(nativeSupport, "library.json"), "native");
    const nativeMedia = path.join(nativeSupport, "Media", "preview.mp3");
    await fs.mkdir(path.dirname(nativeMedia), { recursive: true });
    await fs.writeFile(nativeMedia, "preview-audio");

    const result = await migrateMacNativeData({
      homeDirectory,
      targetUserData,
      platform: "darwin",
      defaults: {
        [MAC_DEFAULT_KEYS.library]: encoded({
          tracks: [{ id: "preview-track", title: "Preview", filePath: nativeMedia }],
        }),
      },
      preserveSources: true,
    });

    assert.equal(result.supportMigrations.at(-1).preservedSource, true);
    assert.equal(await fs.readFile(path.join(targetUserData, "library.json"), "utf8"), "native");
    assert.equal(await fs.readFile(path.join(nativeSupport, "library.json"), "utf8"), "native");
    assert.equal(result.state.tracks[0].filePath, path.join(targetUserData, "Media", "preview.mp3"));
    assert.equal(await fs.readFile(result.state.tracks[0].filePath, "utf8"), "preview-audio");
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("native state merges into an existing Electron library without replacing newer data", () => {
  const merged = mergeMacNativeState({
    tracks: [{ id: "shared", title: "Electron title", filePath: "/electron.mp3" }],
    playlists: [{ id: "mix", name: "Electron Mix", trackIDs: ["shared"] }],
    favorites: ["shared"],
    listeningHistory: [{ id: "electron-history", trackID: "shared" }],
    completedMigrations: ["electron-migration"],
    appPreferences: { theme: "ocean" },
    serverTransferPreferences: {
      "https://electron.example#profile=default": {
        uploadMode: "local_file",
        downloadMode: "verified_file_cache",
      },
    },
  }, {
    tracks: [
      { id: "shared", title: "Native title", artist: "Native artist" },
      { id: "native-only", title: "Native only", filePath: "/native.mp3" },
    ],
    playlists: [{ id: "mix", name: "Native Mix", trackIDs: ["native-only"] }],
    favorites: ["native-only"],
    listeningHistory: [{ id: "native-history", trackID: "native-only" }],
    completedMigrations: [MAC_MIGRATION_ID],
    appPreferences: { theme: "midnight", runInBackground: true },
    serverTransferPreferences: {
      "https://native.example#profile=default": {
        uploadMode: "server_source_link",
        downloadMode: "stream_only",
      },
    },
  });

  assert.deepEqual(merged.tracks.map(({ id }) => id), ["shared", "native-only"]);
  assert.equal(merged.tracks[0].title, "Electron title");
  assert.equal(merged.tracks[0].artist, "Native artist");
  assert.deepEqual(merged.playlists[0].trackIDs, ["shared", "native-only"]);
  assert.deepEqual(merged.favorites, ["shared", "native-only"]);
  assert.deepEqual(merged.listeningHistory.map(({ id }) => id), ["electron-history", "native-history"]);
  assert.deepEqual(merged.completedMigrations, ["electron-migration", MAC_MIGRATION_ID]);
  assert.deepEqual(merged.appPreferences, { theme: "ocean", runInBackground: true });
  assert.deepEqual(merged.serverTransferPreferences, {
    "https://native.example#profile=default": {
      uploadMode: "server_source_link",
      downloadMode: "stream_only",
    },
    "https://electron.example#profile=default": {
      uploadMode: "local_file",
      downloadMode: "verified_file_cache",
    },
  });
});

test("a native defaults read failure does not become an empty migrated library", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "resonance-mac-defaults-failure-test-"));
  try {
    const result = await migrateMacNativeData({
      homeDirectory: path.join(root, "home"),
      targetUserData: path.join(root, "preview"),
      platform: "darwin",
      exec: async () => { throw new Error("defaults unavailable"); },
      readFile: async () => { throw new Error("plist unreadable"); },
      preserveSources: true,
    });
    assert.equal(result.state, null);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("mac native data is a no-op on Windows and paths retain the production identity", async () => {
  const paths = nativeMacPaths({ homeDirectory: "/Users/example", targetUserData: "/Users/example/Library/Application Support/Resonance" });
  assert.equal(MAC_NATIVE_BUNDLE_IDENTIFIER, "com.gavindietrich.LikedSongsFocus");
  assert.equal(paths.nativeSupport, paths.electronUserData);
  const result = await migrateMacNativeData({ platform: "win32", homeDirectory: "/Users/example" });
  assert.deepEqual(result, { migrated: false, state: null, credentials: null, accountSession: null });
});

test("macOS migration rewrites managed media paths into moved and recovered destinations", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "resonance-mac-media-path-migration-"));
  try {
    const homeDirectory = path.join(root, "home");
    const targetUserData = path.join(root, "electron-user-data");
    const legacySupport = path.join(homeDirectory, "Library", "Application Support", "Liked Songs");
    const sourceMedia = path.join(legacySupport, "Media");
    const targetMedia = path.join(targetUserData, "Media");
    const normalSource = path.join(sourceMedia, "normal.mp3");
    const conflictSource = path.join(sourceMedia, "conflict.mp3");
    await fs.mkdir(sourceMedia, { recursive: true });
    await fs.mkdir(targetMedia, { recursive: true });
    await fs.writeFile(normalSource, "native-normal");
    await fs.writeFile(conflictSource, "native-conflict");
    await fs.writeFile(path.join(targetMedia, "conflict.mp3"), "electron-conflict");

    const result = await migrateMacNativeData({
      homeDirectory,
      targetUserData,
      platform: "darwin",
      defaults: {
        [MAC_DEFAULT_KEYS.library]: encoded({
          tracks: [
            { id: "normal", title: "Normal", filePath: normalSource },
            { id: "conflict", title: "Conflict", filePath: conflictSource },
          ],
        }),
      },
    });

    const tracks = new Map(result.state.tracks.map((track) => [track.id, track.filePath]));
    assert.equal(tracks.get("normal"), path.join(targetMedia, "normal.mp3"));
    assert.equal(tracks.get("conflict"), path.join(targetUserData, "Legacy Recovery", "conflict.mp3"));
    assert.equal(await fs.readFile(tracks.get("normal"), "utf8"), "native-normal");
    assert.equal(await fs.readFile(tracks.get("conflict"), "utf8"), "native-conflict");
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("packaged migration copies native data and deletes sources only after cleanup", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "resonance-mac-deferred-migration-"));
  try {
    const homeDirectory = path.join(root, "home");
    const targetUserData = path.join(root, "electron-user-data");
    const legacySupport = path.join(homeDirectory, "Library", "Application Support", "Liked Songs");
    const nativeMedia = path.join(legacySupport, "Media", "deferred.mp3");
    await fs.mkdir(path.dirname(nativeMedia), { recursive: true });
    await fs.writeFile(nativeMedia, "deferred-audio");

    const migration = await migrateMacNativeData({
      homeDirectory,
      targetUserData,
      platform: "darwin",
      defaults: {
        [MAC_DEFAULT_KEYS.library]: encoded({
          tracks: [{ id: "deferred", title: "Deferred", filePath: nativeMedia }],
        }),
      },
      deferSourceDeletion: true,
    });

    assert.equal(migration.copyVerified, true);
    assert.equal(migration.state.tracks[0].filePath, path.join(targetUserData, "Media", "deferred.mp3"));
    assert.equal(await fs.readFile(migration.state.tracks[0].filePath, "utf8"), "deferred-audio");
    assert.equal(await fs.readFile(nativeMedia, "utf8"), "deferred-audio");

    const beforeCleanup = await cleanupMacNativeData({ ...migration, copyVerified: false });
    assert.equal(beforeCleanup.cleaned, false);
    assert.equal(await fs.readFile(nativeMedia, "utf8"), "deferred-audio");

    const afterCleanup = await cleanupMacNativeData(migration);
    assert.equal(afterCleanup.cleaned, true);
    await assert.rejects(fs.access(legacySupport));
    assert.equal(await fs.readFile(path.join(targetUserData, "Media", "deferred.mp3"), "utf8"), "deferred-audio");
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("deferred migration retries do not duplicate identical recovery copies", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "resonance-mac-deferred-retry-"));
  try {
    const homeDirectory = path.join(root, "home");
    const targetUserData = path.join(root, "electron-user-data");
    const legacySupport = path.join(homeDirectory, "Library", "Application Support", "Liked Songs");
    const nativeConflict = path.join(legacySupport, "Media", "same-name.mp3");
    const electronConflict = path.join(targetUserData, "Media", "same-name.mp3");
    await fs.mkdir(path.dirname(nativeConflict), { recursive: true });
    await fs.mkdir(path.dirname(electronConflict), { recursive: true });
    await fs.writeFile(nativeConflict, "native-version");
    await fs.writeFile(electronConflict, "electron-version");

    const defaults = {
      [MAC_DEFAULT_KEYS.library]: encoded({
        tracks: [{ id: "conflict", title: "Conflict", filePath: nativeConflict }],
      }),
    };
    const first = await migrateMacNativeData({
      homeDirectory,
      targetUserData,
      platform: "darwin",
      defaults,
      deferSourceDeletion: true,
    });
    const second = await migrateMacNativeData({
      homeDirectory,
      targetUserData,
      platform: "darwin",
      defaults,
      deferSourceDeletion: true,
    });

    assert.equal(first.copyVerified, true);
    assert.equal(second.copyVerified, true);
    assert.equal(second.state.tracks[0].filePath, path.join(targetUserData, "Legacy Recovery", "same-name.mp3"));
    assert.deepEqual(
      (await fs.readdir(path.join(targetUserData, "Legacy Recovery"))).sort(),
      ["same-name.mp3"],
    );
    assert.equal(await fs.readFile(nativeConflict, "utf8"), "native-version");

    await cleanupMacNativeData(second);
    await assert.rejects(fs.access(legacySupport));
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("deferred migration refuses cleanup after an incomplete copy and recovers on retry", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "resonance-mac-copy-failure-"));
  try {
    const homeDirectory = path.join(root, "home");
    const targetUserData = path.join(root, "electron-user-data");
    const legacySupport = path.join(homeDirectory, "Library", "Application Support", "Liked Songs");
    const nativeMedia = path.join(legacySupport, "Media", "partial.mp3");
    await fs.mkdir(path.dirname(nativeMedia), { recursive: true });
    await fs.mkdir(targetUserData, { recursive: true });
    await fs.writeFile(nativeMedia, "complete-native-audio");

    const flakyFileSystem = {
      ...fs,
      cp: async (_source, destination) => {
        await fs.writeFile(destination, "partial-copy");
      },
    };
    const defaults = {
      [MAC_DEFAULT_KEYS.library]: encoded({
        tracks: [{ id: "partial", title: "Partial", filePath: nativeMedia }],
      }),
    };
    const failed = await migrateMacNativeData({
      homeDirectory,
      targetUserData,
      platform: "darwin",
      defaults,
      fileSystem: flakyFileSystem,
      deferSourceDeletion: true,
    });

    assert.equal(failed.copyVerified, false);
    assert.equal(failed.state, null);
    assert.equal(await fs.readFile(nativeMedia, "utf8"), "complete-native-audio");
    assert.equal((await cleanupMacNativeData(failed)).cleaned, false);

    const retried = await migrateMacNativeData({
      homeDirectory,
      targetUserData,
      platform: "darwin",
      defaults,
      deferSourceDeletion: true,
    });
    assert.equal(retried.copyVerified, true);
    assert.equal(retried.state.tracks[0].filePath, path.join(targetUserData, "Legacy Recovery", "Media", "partial.mp3"));
    assert.equal(await fs.readFile(retried.state.tracks[0].filePath, "utf8"), "complete-native-audio");
    await cleanupMacNativeData(retried);
    await assert.rejects(fs.access(legacySupport));
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});
