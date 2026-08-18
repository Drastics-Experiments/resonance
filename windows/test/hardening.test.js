import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { access, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import crashSafeFile from "../crash-safe-file.cjs";
import downloadFile from "../download-file.cjs";
import filenamePolicy from "../filename-policy.cjs";
import provenance from "../provenance.cjs";
import responseBody from "../response-body.cjs";
import updaterAuth from "../updater-auth.cjs";
import serverPolicy from "../server-policy.cjs";
import {
  canonicalYouTubeSourcePageURL,
  clientConfigRenewalDelay,
  createEmptyState,
  exactYouTubeSourcePageURL,
  mergeListeningHistoryDocument,
  normalizeServerUploadManifest,
  normalizeState,
  physicalStorageClassForTrack,
  persistentPlaybackIDs,
  resolveServerTransferModes,
  SAFE_CLIENT_CONFIG,
  setServerTransferPreference,
  serverUploadConfigurationError,
  serverUploadManifestCanCleanup,
  serverUploadManifestRetryIDs,
  summarizeListeningHistory,
} from "../ui/core.js";

const { crashSafeReplace, readPrimaryOrBackup } = crashSafeFile;
const { MAX_SERVER_MEDIA_BYTES, writeResponseToFile } = downloadFile;
const { sanitizeWindowsFilename, windowsCollisionFilename } = filenamePolicy;
const {
  isEphemeralProviderMediaURL,
  normalizeSourceIdentity,
  normalizeSourceIdentities,
  sanitizePersistedJSON,
  sanitizePersistedSourceIdentity,
} = provenance;
const { readResponseJSON } = responseBody;
const {
  updateAuthenticityPolicy,
  verifyDownloadedWindowsUpdate,
  verifyWindowsUpdatePublisher,
} = updaterAuth;
const { catalogSHA256, normalizeServerBaseURL } = serverPolicy;

async function temporaryDirectory(t) {
  const directory = await mkdtemp(path.join(os.tmpdir(), "resonance-windows-hardening-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

test("requires HTTPS before server credentials leave the client", () => {
  assert.equal(normalizeServerBaseURL("https://Music.Example/api?ignored=1#fragment").href, "https://music.example/api/");
  assert.equal(
    normalizeServerBaseURL("https://music.unblocked.mov").origin,
    "https://resonance-core.blithe-haven-9710.chatgpt.site",
  );
  assert.throws(() => normalizeServerBaseURL("http://music.example"), /https:\/\//i);
  assert.throws(() => normalizeServerBaseURL("http://127.0.0.1"), /local development/i);
  assert.throws(
    () => normalizeServerBaseURL("http://127.0.0.1.evil.example", { allowInsecureLoopback: true }),
    /local development/i,
  );
  assert.throws(
    () => normalizeServerBaseURL("https://token:secret@music.example"),
    /credentials/i,
  );
  for (const address of ["http://localhost:8787", "http://127.0.0.1:8787", "http://[::1]:8787"]) {
    assert.doesNotThrow(() => normalizeServerBaseURL(address, { allowInsecureLoopback: true }));
  }

  assert.equal(serverUploadConfigurationError({ serverURL: "https://music.example", adminToken: "secret" }), null);
  assert.equal(serverUploadConfigurationError({ serverURL: "http://localhost:8787", adminToken: "secret" }), null);
  assert.match(serverUploadConfigurationError({ serverURL: "http://music.example", adminToken: "secret" }), /HTTPS/);
  assert.match(serverUploadConfigurationError({ serverURL: "http://127.0.0.1.evil", adminToken: "secret" }), /HTTPS/);
  assert.match(serverUploadConfigurationError({ serverURL: "https://user:secret@music.example", adminToken: "secret" }), /credentials/);
});

test("uses fail-closed transfer defaults and scopes persisted mode preferences", () => {
  const previousLocalImportFlag = process.env.RESONANCE_LOCAL_DEVICE_IMPORT;
  process.env.RESONANCE_LOCAL_DEVICE_IMPORT = "0";
  try {
    assert.equal(canonicalYouTubeSourcePageURL("https://youtu.be/jNQXAC9IVRw?t=15"), "https://www.youtube.com/watch?v=jNQXAC9IVRw");
    assert.equal(exactYouTubeSourcePageURL(" https://www.youtube.com/watch?v=jNQXAC9IVRw "), "https://www.youtube.com/watch?v=jNQXAC9IVRw");
    for (const unsafe of [
      "https://youtu.be/jNQXAC9IVRw",
      "https://www.youtube.com/shorts/jNQXAC9IVRw",
      "https://www.youtube.com/watch?v=jNQXAC9IVRw&t=15",
      "https://music.youtube.com/watch?v=jNQXAC9IVRw",
    ]) assert.equal(exactYouTubeSourcePageURL(unsafe), null);
  } finally {
    if (previousLocalImportFlag === undefined) delete process.env.RESONANCE_LOCAL_DEVICE_IMPORT;
    else process.env.RESONANCE_LOCAL_DEVICE_IMPORT = previousLocalImportFlag;
  }
  const state = createEmptyState();
  const safe = resolveServerTransferModes({
    state,
    serverURL: "https://music.example/path",
    profileID: "default",
    config: SAFE_CLIENT_CONFIG,
  });
  assert.deepEqual(safe.available, { upload: ["local_file"], download: ["verified_file_cache"] });
  assert.equal(safe.uploadMode, "local_file");
  assert.equal(safe.downloadMode, "verified_file_cache");

  const enabled = {
    ...SAFE_CLIENT_CONFIG,
    verified: true,
    source: "remote",
    issued_at: "2026-08-06T17:55:00.000Z",
    not_before: "2026-08-06T17:55:00.000Z",
    expires_at: "2026-08-06T18:05:00.000Z",
    values: {
      ...SAFE_CLIENT_CONFIG.values,
      "upload.server_source_link": true,
      "upload.reviewed_match": true,
      "matcher.mode": "review",
    },
    kill_switches: { ...SAFE_CLIENT_CONFIG.kill_switches, link_imports: false },
  };
  setServerTransferPreference(state, {
    serverURL: "https://music.example/a",
    profileID: "listener-a",
    uploadMode: "server_source_link",
    downloadMode: "verified_file_cache",
    config: enabled,
    now: Date.parse("2026-08-06T18:00:00.000Z"),
  });
  assert.equal(resolveServerTransferModes({
    state,
    serverURL: "https://music.example/b",
    profileID: "listener-a",
    config: enabled,
    now: Date.parse("2026-08-06T18:00:00.000Z"),
  }).uploadMode, "server_source_link");
  assert.deepEqual(resolveServerTransferModes({
    state: createEmptyState(),
    serverURL: "https://music.example",
    profileID: "listener-a",
    config: enabled,
    now: Date.parse("2026-08-06T18:00:00.000Z"),
    localImportAvailable: false,
  }).available.upload, ["local_file", "server_source_link"]);
  assert.equal(resolveServerTransferModes({
    state,
    serverURL: "https://music.example",
    profileID: "listener-b",
    config: enabled,
    now: Date.parse("2026-08-06T18:00:00.000Z"),
  }).uploadMode, "local_file");

  const disabled = resolveServerTransferModes({
    state,
    serverURL: "https://music.example",
    profileID: "listener-a",
    config: SAFE_CLIENT_CONFIG,
  });
  assert.equal(disabled.uploadMode, "local_file");
  assert.equal(state.serverTransferPreferences[disabled.key].uploadMode, "server_source_link");

  assert.equal(resolveServerTransferModes({
    state,
    serverURL: "https://music.example",
    profileID: "listener-a",
    config: enabled,
    now: Date.parse("2026-08-06T18:05:00.000Z"),
  }).uploadMode, "local_file");

  const reviewedWithoutLocalFiles = {
    ...enabled,
    values: { ...enabled.values, "upload.local_file": false },
  };
  assert.deepEqual(resolveServerTransferModes({
    state: createEmptyState(),
    serverURL: "https://music.example",
    profileID: "listener-a",
    config: reviewedWithoutLocalFiles,
    now: Date.parse("2026-08-06T18:00:00.000Z"),
  }).available.upload, ["server_source_link"]);

  const sourceLinksKilled = {
    ...enabled,
    kill_switches: { ...enabled.kill_switches, link_imports: true },
  };
  assert.deepEqual(resolveServerTransferModes({
    state: createEmptyState(),
    serverURL: "https://music.example",
    profileID: "listener-a",
    config: sourceLinksKilled,
    now: Date.parse("2026-08-06T18:00:00.000Z"),
  }).available.upload, ["local_file", "reviewed_match"]);
});

test("maps stream-only configuration to a non-persistent download mode", () => {
  const state = createEmptyState();
  const config = {
    ...SAFE_CLIENT_CONFIG,
    verified: true,
    issued_at: "2026-08-06T17:55:00.000Z",
    not_before: "2026-08-06T17:55:00.000Z",
    expires_at: "2026-08-06T18:05:00.000Z",
    values: { ...SAFE_CLIENT_CONFIG.values, "download.offline_mode": "stream_only" },
    kill_switches: { ...SAFE_CLIENT_CONFIG.kill_switches, offline_downloads: true },
  };
  const modes = resolveServerTransferModes({
    state,
    serverURL: "https://music.example",
    profileID: "default",
    config,
    now: Date.parse("2026-08-06T18:00:00.000Z"),
  });
  assert.deepEqual(modes.available.download, ["stream_only"]);
  assert.equal(modes.downloadMode, "stream_only");
  assert.equal(clientConfigRenewalDelay(config, Date.parse("2026-08-06T18:00:00.000Z")), 4 * 60 * 1000);
  assert.equal(clientConfigRenewalDelay(config, Date.parse("2026-08-06T18:04:58.000Z")), 5_000);
  assert.equal(clientConfigRenewalDelay(config, Date.parse("2026-08-06T18:05:00.000Z")), 60_000);
  assert.equal(clientConfigRenewalDelay(SAFE_CLIENT_CONFIG, Date.parse("2026-08-06T18:00:00.000Z")), 60_000);
  assert.deepEqual(persistentPlaybackIDs(
    ["local", "stream-runtime", "local"],
    [
      { id: "local", fileUrl: "file:///Music/local.mp3" },
      { id: "stream-runtime", transientStream: true, fileUrl: "resonance-stream://media/secret" },
    ],
  ), ["local"]);
});

test("accepts only a real catalog SHA-256", () => {
  const digest = "a".repeat(64);
  assert.equal(catalogSHA256({ content_sha256: digest.toUpperCase() }), digest);
  assert.equal(catalogSHA256({ contentSha256: digest }), digest);
  assert.equal(catalogSHA256({ content_sha256: "not-a-digest" }), null);
  assert.equal(catalogSHA256({}), null);
});

test("sanitizes reserved and malformed Windows filenames on every host", () => {
  assert.equal(sanitizeWindowsFilename("C:\\Users\\listener\\CON.txt"), "CON_.txt");
  assert.equal(sanitizeWindowsFilename("CON.backup.mp3"), "CON_.backup.mp3");
  assert.equal(sanitizeWindowsFilename("/tmp/LPT9.wav"), "LPT9_.wav");
  assert.equal(sanitizeWindowsFilename("report. "), "report");
  assert.equal(sanitizeWindowsFilename("a<b>:c?.mp3"), "a-b--c-.mp3");
  assert.equal(sanitizeWindowsFilename("AC/DC - Song.mp3", { pathInput: false }), "AC-DC - Song.mp3");
  assert.equal(sanitizeWindowsFilename("...", { fallback: "NUL?.m4a" }), "NUL-.m4a");
  assert.equal(sanitizeWindowsFilename(""), "");
  assert.ok(sanitizeWindowsFilename(`${"a".repeat(100)}.mp3`, { maximumLength: 24 }).length <= 24);
  const collision = windowsCollisionFilename(`${"a".repeat(236)}.mp3`, 27);
  assert.ok(collision.length <= 240);
  assert.match(collision, / 27\.mp3$/);
});

test("persists bounded structured source provenance without unsafe URLs", () => {
  const value = normalizeSourceIdentity({
    provider: "soundcloud",
    providerID: "track-123",
    sourcePageURL: "https://soundcloud.example/artist/song",
    mediaSourceURL: "https://cdn.example/audio?id=123",
    confidence: "fingerprint-and-metadata",
    score: 1.5,
    evidence: { fingerprintDistance: 0.02, durationMatched: true, nested: { ignored: true } },
  });
  assert.deepEqual(value, {
    provider: "soundcloud",
    providerID: "track-123",
    sourcePageURL: "https://soundcloud.example/artist/song",
    mediaSourceURL: "https://cdn.example/audio?id=123",
    confidence: "fingerprint-and-metadata",
    score: 1,
    evidence: { fingerprintDistance: 0.02, durationMatched: true },
  });
  assert.equal(normalizeSourceIdentity({ sourcePageURL: "javascript:alert(1)" }), null);
  assert.equal(normalizeSourceIdentity({ sourcePageURL: "https://user:secret@example.com/song" }), null);
  assert.equal(normalizeSourceIdentity({ mediaSourceURL: "file:///private/song.mp3" }), null);

  assert.equal(isEphemeralProviderMediaURL("https://r1---sn.googlevideo.com/videoplayback?expire=1"), true);
  assert.equal(isEphemeralProviderMediaURL("https://cf-media.sndcdn.com/song.mp3?Policy=short-lived"), true);
  assert.equal(isEphemeralProviderMediaURL("https://p.scdn.co/mp3-preview/track.mp3?token=short-lived"), true);
  assert.equal(isEphemeralProviderMediaURL("https://resonance.example/api/v1/songs/song-a"), false);
  assert.equal(normalizeSourceIdentity({
    sourcePageURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
    mediaSourceURL: "https://r1---sn.googlevideo.com/videoplayback?expire=1",
  }).mediaSourceURL, "https://r1---sn.googlevideo.com/videoplayback?expire=1");
  assert.equal(sanitizePersistedSourceIdentity({
    sourcePageURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
    mediaSourceURL: "https://r1---sn.googlevideo.com/videoplayback?expire=1",
  }).sourcePageURL, "https://www.youtube.com/watch?v=jNQXAC9IVRw");
  assert.equal(sanitizePersistedSourceIdentity({
    sourcePageURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
    mediaSourceURL: "https://r1---sn.googlevideo.com/videoplayback?expire=1",
  }).mediaSourceURL, null);
  assert.equal(sanitizePersistedSourceIdentity({
    sourcePageURL: "https://resonance.example/api/v1/songs/song-a",
    mediaSourceURL: "https://resonance.example/api/v1/songs/song-a/download",
  }).mediaSourceURL, "https://resonance.example/api/v1/songs/song-a/download");
  assert.deepEqual(sanitizePersistedJSON({
    sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
    mediaSourceURL: "https://r1---sn.googlevideo.com/videoplayback?expire=1",
    nested: ["https://cf-media.sndcdn.com/song.mp3?Policy=short-lived"],
    "audio:https://r1---sn.googlevideo.com/videoplayback?expire=1": { cached: true },
  }), {
    sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
    mediaSourceURL: null,
    nested: [null],
  });

  const repeatedAlias = { provider: "youtube", providerID: "video-1" };
  const withAliases = normalizeSourceIdentity({
    provider: "spotify",
    providerID: "track-1",
    aliases: [repeatedAlias, repeatedAlias, ...Array.from({ length: 12 }, (_, index) => ({
      provider: "provider",
      providerID: `alias-${index}`,
    }))],
  });
  assert.equal(withAliases.aliases.length, 8);
  assert.equal(withAliases.aliases.filter((identity) => identity.providerID === "video-1").length, 1);
  assert.equal(normalizeSourceIdentities([repeatedAlias, repeatedAlias]).length, 1);
});

test("bounds JSON response bodies before parsing", async () => {
  const body = JSON.stringify({ ok: true });
  assert.deepEqual(await readResponseJSON(new Response(body), 128, "test response"), { ok: true });
  const oversized = new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(new TextEncoder().encode("{" + "x".repeat(140)));
      controller.close();
    },
  }));
  await assert.rejects(readResponseJSON(oversized, 128, "test response"), /too large/);
});

test("pins Windows update identity to the installed Authenticode signer", async () => {
  const current = {
    status: "Valid",
    subject: "CN=Resonance Release, O=Resonance",
    issuer: "CN=Trusted Issuer",
    thumbprint: "a".repeat(40),
  };
  const same = { ...current };
  assert.equal(verifyWindowsUpdatePublisher({
    currentSignature: current,
    updateSignature: same,
    authenticityMode: "production",
  }).verified, true);
  assert.throws(() => verifyWindowsUpdatePublisher({
    currentSignature: current,
    updateSignature: { ...same, thumbprint: "b".repeat(40) },
    authenticityMode: "production",
  }), /different publisher identity/);
  assert.deepEqual(updateAuthenticityPolicy({
    packaged: false,
    environment: { NODE_ENV: "test", RESONANCE_ALLOW_UNSIGNED_UPDATE_TESTS: "1" },
  }), { authenticityMode: "test", requirePublisher: false, exception: "test" });
  const reads = [];
  const result = await verifyDownloadedWindowsUpdate({
    downloadedFile: "C:\\Updates\\Resonance-Setup-2.0.1.exe",
    currentExecutable: "C:\\Program Files\\Resonance\\Resonance.exe",
    authenticityMode: "production",
    readSignature: async (filePath) => {
      reads.push(filePath);
      return current;
    },
  });
  assert.equal(result.verified, true);
  assert.equal(reads.length, 2);
});

test("uses the immutable packaged update policy for explicitly unsigned Windows builds", async () => {
  const reads = [];
  const unsigned = { status: "NotSigned", subject: null, issuer: null, thumbprint: null };
  const result = await verifyDownloadedWindowsUpdate({
    downloadedFile: "C:\\Updates\\Resonance-Setup-2.0.1.exe",
    currentExecutable: "C:\\Program Files\\Resonance\\Resonance.exe",
    authenticityMode: "unsigned",
    packaged: true,
    environment: {
      NODE_ENV: "production",
      RESONANCE_ALLOW_UNSIGNED_UPDATE_TESTS: "0",
    },
    readSignature: async (filePath) => {
      reads.push(filePath);
      return unsigned;
    },
  });
  assert.deepEqual(result, {
    authenticityMode: "unsigned",
    verified: true,
    authenticode: false,
    exception: "explicit-unsigned-release",
  });
  assert.equal(reads.length, 2);

  assert.throws(() => verifyWindowsUpdatePublisher({
    currentSignature: {
      status: "Valid",
      subject: "CN=Resonance Release, O=Resonance",
      issuer: "CN=Trusted Issuer",
      thumbprint: "a".repeat(40),
    },
    updateSignature: unsigned,
    authenticityMode: "unsigned",
  }), /both executables to be explicitly unsigned/i);
  assert.throws(() => verifyWindowsUpdatePublisher({
    currentSignature: unsigned,
    updateSignature: { status: "HashMismatch" },
    authenticityMode: "unsigned",
  }), /both executables to be explicitly unsigned/i);

  assert.throws(() => updateAuthenticityPolicy({
    packaged: true,
    environment: { NODE_ENV: "test", RESONANCE_ALLOW_UNSIGNED_UPDATE_TESTS: "1" },
  }), /no valid update authenticity policy/i);
  assert.throws(() => updateAuthenticityPolicy({
    authenticityMode: "unexpected",
    packaged: true,
  }), /no valid update authenticity policy/i);
  assert.deepEqual(updateAuthenticityPolicy({
    authenticityMode: "production",
    packaged: true,
    environment: { NODE_ENV: "test", RESONANCE_ALLOW_UNSIGNED_UPDATE_TESTS: "1" },
  }), {
    authenticityMode: "production",
    requirePublisher: true,
    exception: null,
  });
});

test("downloads require exact declared size and SHA-256 before adoption", async (t) => {
  const directory = await temporaryDirectory(t);
  const body = Buffer.from("verified server audio");
  const digest = sha256(body);
  const destination = path.join(directory, "verified.part");
  const response = new Response(body, { headers: { "content-length": String(body.length) } });

  assert.deepEqual(await writeResponseToFile(response, destination, {
    expectedSize: body.length,
    expectedSHA256: digest,
  }), { size: body.length, sha256: digest });
  assert.deepEqual(await readFile(destination), body);
});

test("failed or oversized downloads leave no partial file", async (t) => {
  const directory = await temporaryDirectory(t);
  const body = Buffer.from("tampered server audio");
  const hashMismatch = path.join(directory, "hash-mismatch.part");
  await assert.rejects(writeResponseToFile(
    new Response(body, { headers: { "content-length": String(body.length) } }),
    hashMismatch,
    { expectedSize: body.length, expectedSHA256: sha256("different") },
  ), /SHA-256 verification/);
  await assert.rejects(access(hashMismatch), { code: "ENOENT" });

  const overrun = path.join(directory, "overrun.part");
  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue(Buffer.from("ab"));
      controller.enqueue(Buffer.from("cd"));
      controller.close();
    },
  });
  await assert.rejects(writeResponseToFile(
    { body: stream, headers: { get: () => "3" } },
    overrun,
    { expectedSize: 3, expectedSHA256: sha256("abc") },
  ), /exceeded/);
  await assert.rejects(access(overrun), { code: "ENOENT" });

  let cancelled = false;
  await assert.rejects(writeResponseToFile({
    body: { cancel: async () => { cancelled = true; } },
    headers: { get: () => String(MAX_SERVER_MEDIA_BYTES + 1) },
  }, path.join(directory, "oversized.part"), {
    expectedSize: MAX_SERVER_MEDIA_BYTES + 1,
    expectedSHA256: "a".repeat(64),
  }), /supported download size/);
  assert.equal(cancelled, true);
});

test("credential replacement keeps a recoverable backup and repairs the primary", async (t) => {
  const directory = await temporaryDirectory(t);
  const destination = path.join(directory, "server-credentials.bin");
  const backup = `${destination}.backup`;
  const parse = (buffer) => JSON.parse(buffer.toString("utf8"));

  await crashSafeReplace(destination, JSON.stringify({ version: 1 }), { backupPath: backup });
  await crashSafeReplace(destination, JSON.stringify({ version: 2 }), { backupPath: backup });
  assert.deepEqual(parse(await readFile(destination)), { version: 2 });
  assert.deepEqual(parse(await readFile(backup)), { version: 1 });
  if (process.platform !== "win32") {
    assert.equal((await stat(destination)).mode & 0o777, 0o600);
    assert.equal((await stat(backup)).mode & 0o777, 0o600);
  }

  await writeFile(destination, "corrupt-primary");
  const recovered = await readPrimaryOrBackup(destination, parse, { backupPath: backup });
  assert.equal(recovered.recoveredFromBackup, true);
  assert.deepEqual(recovered.value, { version: 1 });
  assert.deepEqual(parse(await readFile(destination)), { version: 1 });
});

test("history identity and summaries remain isolated by server origin and profile", () => {
  const startedAt = "2026-08-05T12:00:00.000Z";
  const state = normalizeState({
    ...createEmptyState(),
    serverURL: "https://one.example/library",
    syncProfileID: "listener",
    tracks: [
      { id: "one", remoteID: "song", sourceServer: "https://one.example", syncProfileID: "listener", title: "One" },
      { id: "two", remoteID: "song", sourceServer: "https://two.example", syncProfileID: "listener", title: "Two" },
    ],
    listeningHistory: [
      { id: "same-event", trackID: "one", profileID: "listener", serverOrigin: "https://one.example", startedAt, listenedSeconds: 10 },
      { id: "same-event", trackID: "two", profileID: "listener", serverOrigin: "https://two.example", startedAt, listenedSeconds: 20 },
    ],
  });

  const now = new Date("2026-08-06T12:00:00.000Z");
  assert.equal(summarizeListeningHistory(state, 30, now).totalSeconds, 10);
  state.serverURL = "https://two.example";
  assert.equal(summarizeListeningHistory(state, 30, now).totalSeconds, 20);

  state.serverURL = "https://one.example";
  assert.equal(mergeListeningHistoryDocument(state, {
    profile_id: "listener",
    server_origin: "https://one.example",
    entries: [{ id: "same-event", track_id: "one", started_at: startedAt, listened_seconds: 15 }],
  }, "listener", state.serverURL), true);
  assert.equal(state.listeningHistory.length, 2);
  assert.equal(state.listeningHistory.find((entry) => entry.serverOrigin === "https://one.example").listenedSeconds, 15);
  assert.equal(mergeListeningHistoryDocument(state, {
    profile_id: "listener",
    server_origin: "https://other.example",
    entries: [],
  }, "listener", state.serverURL), false);

  const migratedLegacyState = normalizeState({
    ...createEmptyState(),
    serverURL: "https://legacy.example/api",
    tracks: [{ id: "legacy", remoteID: "remote-without-origin" }],
    listeningHistory: [{ id: "legacy-event", trackID: "legacy", remoteID: "remote-without-origin", startedAt, listenedSeconds: 60 }],
  });
  assert.equal(migratedLegacyState.tracks[0].sourceServer, null);
  assert.equal(migratedLegacyState.listeningHistory[0].serverOrigin, null);
  assert.equal(summarizeListeningHistory(migratedLegacyState, 30, now).totalSeconds, 0);

  const quarantinedLegacyState = normalizeState({
    ...createEmptyState(),
    serverURL: "https://known.example",
    tracks: [
      { id: "legacy-a", filePath: "C:\\Music\\A.mp3", remoteID: "same-id" },
      { id: "legacy-b", filePath: "C:\\Music\\B.mp3", remoteID: "same-id" },
      { id: "known", filePath: "C:\\Music\\Known.mp3", remoteID: "same-id", sourceServer: "https://known.example" },
    ],
    playlists: [
      { id: "liked", name: "Liked Songs", trackIDs: [], isSystem: true },
      { id: "legacy-list", name: "Legacy", trackIDs: ["legacy-a", "legacy-b"], isSystem: false },
    ],
    listeningHistory: [{
      id: "legacy-collision-event",
      trackID: "legacy-a",
      remoteID: "same-id",
      profileID: "default",
      startedAt,
      listenedSeconds: 30,
    }],
  });
  assert.deepEqual(quarantinedLegacyState.tracks.map((track) => track.id), ["legacy-a", "legacy-b", "known"]);
  assert.deepEqual(quarantinedLegacyState.playlists.find((playlist) => playlist.id === "legacy-list").trackIDs, ["legacy-a", "legacy-b"]);
  assert.equal(quarantinedLegacyState.listeningHistory[0].serverOrigin, null);
  assert.equal(summarizeListeningHistory(quarantinedLegacyState, 30, now).totalSeconds, 0);

  const legacyHistory = normalizeState({
    ...createEmptyState(),
    serverURL: "https://current.example",
    tracks: [
      { id: "remote", remoteID: "remote-song", sourceServer: "https://old.example" },
      { id: "local", title: "Local song" },
    ],
    listeningHistory: [
      { id: "remote-event", trackID: "remote", remoteID: "remote-song", profileID: "default", startedAt, listenedSeconds: 10 },
      { id: "local-event", trackID: "local", profileID: "default", startedAt, listenedSeconds: 20 },
    ],
  });
  assert.equal(legacyHistory.listeningHistory.find((entry) => entry.id === "remote-event").serverOrigin, "https://old.example");
  assert.equal(legacyHistory.listeningHistory.find((entry) => entry.id === "local-event").serverOrigin, null);
  assert.equal(summarizeListeningHistory(legacyHistory, 30, now).totalSeconds, 0);
  legacyHistory.serverURL = "https://old.example";
  assert.equal(summarizeListeningHistory(legacyHistory, 30, now).totalSeconds, 10);
});

test("storage classification follows physical location instead of remote association", () => {
  assert.equal(physicalStorageClassForTrack({ remoteID: "uploaded", storageLocation: "local" }), "files");
  assert.equal(physicalStorageClassForTrack({ storageLocation: "server-cache" }), "downloads");
  assert.equal(physicalStorageClassForTrack({ remoteID: "download", storageLocation: "external" }), "external");
  assert.equal(physicalStorageClassForTrack({ remoteID: "legacy" }), "downloads");
});

test("upload manifests retain per-file failures and never allow cleanup before success", () => {
  const manifest = normalizeServerUploadManifest({
    id: "batch-1",
    serverOrigin: "https://music.example/api",
    profileID: "listener",
    source: "picker",
    startedAt: "2026-08-06T12:00:00.000Z",
    items: [
      { retryID: "success", title: "Uploaded", status: "uploaded", attempts: 1, remoteID: "remote-1" },
      { retryID: "retry", title: "Failed", status: "failed", attempts: 3, message: "HTTP 503" },
    ],
  });
  assert.equal(manifest.serverOrigin, "https://music.example");
  assert.deepEqual(serverUploadManifestRetryIDs(manifest), ["retry"]);
  assert.equal(serverUploadManifestCanCleanup(manifest), false);
  manifest.items[1].status = "uploaded";
  manifest.items[1].message = null;
  assert.equal(serverUploadManifestCanCleanup(manifest), true);

  const linkImportManifest = normalizeServerUploadManifest({
    ...manifest,
    id: "link-import-batch",
    source: "link-import",
  });
  assert.equal(linkImportManifest.source, "link-import");
});

test("Windows renderer and main-process integrations retain the hardening boundaries", async () => {
  const [mainSource, preloadSource, appSource, htmlSource, packageSource, launcherSource, serverDownloadSource, downloadFileSource] = await Promise.all([
    readFile(new URL("../main.cjs", import.meta.url), "utf8"),
    readFile(new URL("../preload.cjs", import.meta.url), "utf8"),
    readFile(new URL("../ui/app.js", import.meta.url), "utf8"),
    readFile(new URL("../ui/index.html", import.meta.url), "utf8"),
    readFile(new URL("../package.json", import.meta.url), "utf8"),
    readFile(new URL("../../.launcher-terminal.zsh", import.meta.url), "utf8"),
    readFile(new URL("../server-download.cjs", import.meta.url), "utf8"),
    readFile(new URL("../download-file.cjs", import.meta.url), "utf8"),
  ]);
  const packageJSON = JSON.parse(packageSource);
  const retiredStorageName = ["Liked", " Songs"].join("");

  assert.match(mainSource, /normalizeServerBaseURL\(value, \{ allowInsecureLoopback: !app\.isPackaged \}\)/);
  assert.match(mainSource, /writeResponseToFile\(response, temporary,[\s\S]+expectedSize,[\s\S]+expectedSHA256,[\s\S]+maximumBytes: MAX_SERVER_MEDIA_BYTES/);
  assert.match(mainSource, /ipcMain\.handle\("library:load"[\s\S]+available: false,[\s\S]+missing: true,[\s\S]+stored\.tracks = tracks/);
  assert.match(mainSource, /readPrimaryOrBackup\(credentials,[\s\S]+backupPath: credentialsBackup/);
  assert.match(mainSource, /crashSafeReplace\(credentials,[\s\S]+backupPath: credentialsBackup/);
  assert.match(mainSource, /ipcMain\.handle\("library:storage"[\s\S]+sumDirectory\(paths\.local\)[\s\S]+sumDirectory\(paths\.remote\)/);
  assert.match(mainSource, /encodedSongID = encodeURIComponent\(String\(songID \|\| ""\)\)[\s\S]+api\/v1\/admin\/songs\/\$\{encodedSongID\}/);
  assert.match(mainSource, /setWindowOpenHandler\(\(\) => \(\{ action: "deny" \}\)\)[\s\S]+will-navigate[\s\S]+targetURL !== trustedRendererURL[\s\S]+will-attach-webview/);
  assert.match(mainSource, /openAccountSignInBrowser\(destination\)[\s\S]+shell\.openExternal\(destination\.href\)/);
  assert.match(mainSource, /fetchAccountAvatar\([\s\S]+decodeAccountAvatar/);
  assert.match(mainSource, /nativeImage\.createFromBuffer\([\s\S]+image\.toPNG\(\)/);
  assert.match(mainSource, /persistAccountSession\([\s\S]+isSafeAccountAvatarDataURL/);
  assert.match(appSource, /function safeAccountAvatarDataURL\([\s\S]+ACCOUNT_AVATAR_DATA_URL_PATTERN/);
  assert.match(appSource, /activeProfilePicture = safeAccountAvatarDataURL\(accountSession\?\.imageURL\)/);
  assert.doesNotMatch(mainSource, /function isAllowedAccountAuthNavigation|resonance-clerk-auth-/);
  assert.match(mainSource, /ipcMain\.handle\("account:sign-in"[\s\S]+openAccountSignInBrowser\(destination\)/);
  assert.match(
    mainSource,
    /ipcMain\.handle\("account:sign-in", async \(_event, value\) => \{\s+const baseURL = normalizeServerBaseURL\(ACCOUNT_SIGN_IN_URL\)\.origin;/,
  );
  assert.doesNotMatch(appSource, /signInAccount\(\{\s*baseURL:/);
  assert.match(appSource, /serverURL"\)\.value = RESONANCE_ACCOUNT_SERVER_URL;/);
  assert.match(appSource, /serverURL"\)\.readOnly = true;/);
  assert.deepEqual(packageJSON.build.protocols.flatMap((entry) => entry.schemes), ["resonance"]);
  assert.match(mainSource, /setAsDefaultProtocolClient\("resonance"[\s\S]+app\.on\("second-instance"[\s\S]+authCallbackFromArguments\(commandLine\)/);
  assert.match(mainSource, /previewCredentialStorePath\(\)[\s\S]+app\.getPath\("userData"\)[\s\S]+server-credentials\.json/);
  assert.match(mainSource, /previewAccountSessionPath\(\)[\s\S]+app\.getPath\("userData"\)[\s\S]+account-session\.json/);
  assert.doesNotMatch(
    mainSource,
    new RegExp(
      String.raw`app\.getPath\("appData"\), "${retiredStorageName}", (?:"server-credentials\.json"|"account-session\.json")`,
    ),
  );
  assert.match(preloadSource, /exposeInMainWorld\("resonance"/);
  assert.match(appSource, /const api = window\.resonance;/);
  assert.match(launcherSource, /CFBundleURLTypes[\s\S]+CFBundleURLSchemes\.0 -string resonance/);
  assert.match(launcherSource, /RES_WINDOWS_APP_ROOT="\$HOME\/Library\/Application Support\/Resonance Worktrees\/\$RES_WORKTREE_ID\/Applications"/);
  assert.doesNotMatch(launcherSource, /RES_WINDOWS_APP="\$RES_LAUNCHER_ROOT\/windows/);
  assert.match(launcherSource, /CFBundleTypeRole -string Viewer/);
  assert.match(
    launcherSource,
    /codesign --force --deep --sign - "\$RES_ELECTRON_APP"[\s\S]+RES_LAUNCH_SERVICES_REGISTER" -f "\$RES_ELECTRON_APP"[\s\S]+open -n "\$RES_ELECTRON_APP"/,
  );
  assert.match(appSource, /Complete sign-in in your web browser\./);
  assert.match(mainSource, /serverUploadRetries[\s\S]+retryIDs[\s\S]+serverOrigin === base\.origin[\s\S]+persistServerUploadRetries/);
  assert.match(mainSource, /const MAX_SERVER_UPLOAD_BATCH_FILES = 500;[\s\S]+const MAX_SERVER_UPLOAD_MANIFESTS = 20;[\s\S]+const MAX_SERVER_UPLOAD_RETRY_RECORDS = MAX_SERVER_UPLOAD_BATCH_FILES \* MAX_SERVER_UPLOAD_MANIFESTS;/);
  assert.match(mainSource, /async function loadClientConfig\([\s\S]+const evictCache = async[\s\S]+response\.status >= 500\) return cachedResult\(\);[\s\S]+response\.status !== 200\)[\s\S]+await evictCache\(\)[\s\S]+verifyClientConfigResponse\([\s\S]+catch \{[\s\S]+await evictCache\(\)/);
  assert.match(mainSource, /mode === "reviewed_match"[\s\S]+values\["upload\.reviewed_match"\] === true[\s\S]+values\["upload\.local_file"\] === true[\s\S]+values\["matcher\.mode"\] === "review"/);
  const sourceImportHandler = mainSource.slice(
    mainSource.indexOf('ipcMain.handle("server:source-import"'),
    mainSource.indexOf('ipcMain.handle("server:profiles:get"'),
  );
  const localRawUploadHandler = mainSource.slice(
    mainSource.indexOf('ipcMain.handle("local-import:upload"'),
    mainSource.indexOf('ipcMain.handle("library:delete"'),
  );
  const externalImportHandler = mainSource.slice(
    mainSource.indexOf('ipcMain.handle("local-import:start-external"'),
    mainSource.indexOf('ipcMain.handle("local-import:start"'),
  );
  const mediaRefreshHelper = mainSource.slice(
    mainSource.indexOf("async function refreshedSongDownloadURL"),
    mainSource.indexOf('ipcMain.handle("server:sync"'),
  );
  const serverSyncHandler = mainSource.slice(
    mainSource.indexOf('ipcMain.handle("server:sync"'),
    mainSource.indexOf('ipcMain.handle("server:upload"'),
  );
  const replaceServerCatalogBody = appSource.slice(
    appSource.indexOf("function replaceServerCatalog(songs)"),
    appSource.indexOf("function markPlaylistDirty"),
  );
  const refreshServerCatalogAfterUploadBody = appSource.slice(
    appSource.indexOf("async function refreshServerCatalogAfterUpload(context)"),
    appSource.indexOf("function scheduleServerCatalogRefresh"),
  );
  const rememberUploadedServerSongsBody = appSource.slice(
    appSource.indexOf("function rememberUploadedServerSongs(results)"),
    appSource.indexOf("function serverCatalogMatchForLocalImport"),
  );
  const rawUploadHandler = mainSource.slice(
    mainSource.indexOf('ipcMain.handle("server:upload"'),
    mainSource.indexOf('ipcMain.handle("server:cancel-transfer"'),
  );
  const serverDeleteHandler = mainSource.slice(
    mainSource.indexOf('ipcMain.handle("server:delete"'),
    mainSource.indexOf('ipcMain.handle("server:open-admin"'),
  );
  const resolveLinkImportHandler = appSource.slice(
    appSource.indexOf("async function resolveLinkImport()"),
    appSource.indexOf("async function confirmPlaylistImport()"),
  );
  const directSourceImportHandler = appSource.slice(
    appSource.indexOf("async function confirmServerSourceImport()"),
    appSource.indexOf("async function confirmLinkImport()"),
  );
  const confirmLinkImportHandler = appSource.slice(
    appSource.indexOf("async function confirmLinkImport()"),
    appSource.indexOf("async function cancelLinkImport()"),
  );
  const sourceLinkBody = mainSource.slice(
    mainSource.indexOf("function sourceLinkRegistrationBody"),
    mainSource.indexOf("async function ensureServerUploadRetriesLoaded"),
  );
  assert.match(sourceLinkBody, /const sourceURL = transientMediaSourceURL\(item\.mediaSourceURL\)/);
  assert.doesNotMatch(sourceLinkBody, /const sourceURL = preservedMediaSourceURL\(item\.mediaSourceURL\)/);
  assert.match(sourceLinkBody, /schema_version: 3,[\s\S]+source_url: sourceURL/);
  assert.match(sourceLinkBody, /media_kind: item\.mediaKind === "video" \? "video" : "audio"/);
  assert.match(sourceLinkBody, /schemaVersion === 2[\s\S]+schema_version: 2,[\s\S]+source_url: sourceURL/);
  assert.match(sourceLinkBody, /item\.mediaKind !== "video" && response\.status === 400/);
  assert.match(sourceLinkBody, /payload\?\.error === "Unsupported source-link schema_version"/);
  assert.match(sourceLinkBody, /putSourceLinkRegistration/);
  assert.doesNotMatch(sourceLinkBody, /filename,|metadata:|title:|artist:|album:|duration_seconds|artwork_url/);
  assert.match(sourceImportHandler, /source_page_url: sourcePageURL/);
  assert.doesNotMatch(sourceImportHandler, /filename:|metadata:|title:|artist:|album:|duration_seconds|artwork_url/);
  assert.match(sourceImportHandler, /api\/v1\/admin\/source-imports/);
  assert.match(sourceImportHandler, /settings\.mode !== "server_source_link"/);
  assert.doesNotMatch(sourceImportHandler, /reviewed_match/);
  assert.match(sourceImportHandler, /response\.status === 409[\s\S]+payload\.status !== "duplicate"[\s\S]+payload\.duplicate_of/);
  assert.doesNotMatch(sourceImportHandler, /payload\?\.song \|\| payload\?\.duplicate_of|duplicateOf/);
  assert.match(mainSource, /redirect: "manual"/);
  assert.match(localRawUploadHandler, /clientConfigContext\(base\.href, profileID\)/);
  assert.match(localRawUploadHandler, /requestedMode = \["server_source_link", "reviewed_match"\]\.includes\(mode\) \? mode : "local_file"/);
  assert.match(localRawUploadHandler, /requireClientUploadMode\(\{[\s\S]+mode: requestedMode,[\s\S]+force: true,[\s\S]+controller\.signal\.throwIfAborted\(\);[\s\S]+putSourceLinkRegistration\(\{/);
  assert.match(localRawUploadHandler, /adminToken = canonicalCredentialToken\(adminToken\)[\s\S]+\.\.\.profileHeaders\(adminToken, profileID\),[\s\S]+\.\.\.requestContext\.expected\.request_headers/);
  assert.match(sourceLinkBody, /method: "PUT",[\s\S]+redirect: "manual"/);
  assert.match(localRawUploadHandler, /"Content-Type": "application\/json"/);
  assert.doesNotMatch(localRawUploadHandler, /createReadStream|application\/octet-stream|duplex: "half"/);
  assert.match(sourceImportHandler, /requireClientUploadMode\(\{[\s\S]+mode: "server_source_link",[\s\S]+force: true,[\s\S]+const response = await fetchSameOrigin\(base, new URL\("api\/v1\/admin\/source-imports"/);
  assert.match(externalImportHandler, /requireClientUploadMode\(\{[\s\S]+mode: "external_object",[\s\S]+force: true,[\s\S]+importFileBackedSource/);
  assert.match(rawUploadHandler, /clientConfigContext\(base\.href, requestedProfileID\)/);
  assert.match(rawUploadHandler, /\.\.\.profileHeaders\(adminToken, requestedProfileID\),[\s\S]+\.\.\.requestContext\.expected\.request_headers/);
  assert.match(rawUploadHandler, /while \(attempts < 3 && !remoteSong\)[\s\S]+requireClientUploadMode\(\{[\s\S]+mode: "local_file",[\s\S]+force: true,[\s\S]+signal\.throwIfAborted\(\);[\s\S]+putSourceLinkRegistration\(\{/);
  assert.match(rawUploadHandler, /putSourceLinkRegistration\(\{[\s\S]+"Content-Type": "application\/json"[\s\S]+item,/);
  assert.match(rawUploadHandler, /for \(const item of requestedFiles\)[\s\S]+\{ song: remoteSong, duplicate \}[\s\S]+if \(duplicate\) duplicates \+= 1;[\s\S]+completed \+= 1;/);
  assert.doesNotMatch(rawUploadHandler, /createReadStream\(filePath\)|application\/octet-stream|duplex: "half"/);
  assert.match(mainSource, /error\.name = "ClientUploadPolicyError";[\s\S]+error\.retryable = false;/);
  assert.match(rawUploadHandler, /if \(error\?\.retryable === false\) throw error;[\s\S]+policyBlockedUploadEntries\([\s\S]+completedRetryIDs[\s\S]+rememberRetry\(item\);[\s\S]+failed\.push\(failure\);[\s\S]+return \{ uploaded, duplicates, results, failed, policyBlocked: true \}/);
  assert.match(serverSyncHandler, /clientConfigContext\(base\.href, profileID\)/);
  assert.match(serverSyncHandler, /const downloadHeaders = \{[\s\S]+\.\.\.profileHeaders\(token, profileID\),[\s\S]+\.\.\.requestContext\.expected\.request_headers/);
  assert.match(serverSyncHandler, /const reservedDownloadDestinations = new Set\(\);[\s\S]+for \(const pending of pendingDownloads\)[\s\S]+pending\.destination = destination/);
  assert.match(serverSyncHandler, /runServerDownloadPool\(pendingDownloads,[\s\S]+concurrency: SERVER_DOWNLOAD_DESKTOP_CONCURRENCY/);
  assert.equal([...serverSyncHandler.matchAll(/headers: downloadHeaders/g)].length, 2);
  assert.match(serverSyncHandler, /catalog = serverCatalogSnapshot\(event\.sender\.id, base, token, profileID\)[\s\S]+if \(!catalog\)[\s\S]+fetchServerCatalogDocument/);
  assert.match(mainSource, /function serverCatalogSnapshot\([\s\S]+serverCatalogSnapshots\.read\(ownerID,[\s\S]+origin: base\.origin[\s\S]+profileID: String\(profileID \|\| "default"\)[\s\S]+credentialFingerprint: serverCatalogCredentialFingerprint\(token\)/);
  assert.match(mainSource, /ipcMain\.handle\("server:catalog"[\s\S]+rememberServerCatalogSnapshot\(event\.sender\.id, base, token, profileID, catalog\)/);
  assert.match(mainSource, /window\.webContents\.once\("destroyed"[\s\S]+serverCatalogSnapshots\.clear\(windowWebContentsID\)/);
  assert.match(mainSource, /if \(previousFingerprint !== nextFingerprint\)[\s\S]+serverCatalogSnapshots\.clear\(event\.sender\.id\)/);
  assert.match(mainSource, /function invalidateServerCatalogSnapshots\(base, profileID\)[\s\S]+serverCatalogSnapshots\.clearContext\(\{[\s\S]+origin: base\.origin,[\s\S]+profileID: String\(profileID \|\| "default"\)/);
  assert.match(localRawUploadHandler, /if \(response\.status === 201 \|\| response\.status === 409\) \{[\s\S]+invalidateServerCatalogSnapshots\(base, profileID\);[\s\S]+readServerUploadResponse/);
  assert.match(sourceImportHandler, /if \(response\.status === 201 \|\| response\.status === 409\) \{[\s\S]+invalidateServerCatalogSnapshots\(base, profileID\);[\s\S]+finishLocalImport/);
  assert.match(rawUploadHandler, /if \(response\.status === 201 \|\| response\.status === 409\) \{[\s\S]+invalidateServerCatalogSnapshots\(base, requestedProfileID\);[\s\S]+readServerUploadResponse/);
  assert.match(serverDeleteHandler, /if \(!response\.ok\)[\s\S]+invalidateServerCatalogSnapshots\(base, profileID\);[\s\S]+return true/);
  assert.match(mainSource, /class OfflineDownloadPolicyError extends Error[\s\S]+async function beginOfflineDownloadPolicyLease[\s\S]+createRenewablePolicyLease\(\{[\s\S]+allowUnsignedInitial:[\s\S]+errorFactory/);
  const offlineLeaseSource = mainSource.slice(
    mainSource.indexOf("async function beginOfflineDownloadPolicyLease"),
    mainSource.indexOf("async function requireServerStreamMode"),
  );
  assert.match(offlineLeaseSource, /requireOfflineDownloadMode\(\{ baseURL, token, profileID, force: false \}\)/);
  assert.match(offlineLeaseSource, /renew: \(\) => requireOfflineDownloadMode\(\{ baseURL, token, profileID, force: true \}\)/);
  assert.match(serverSyncHandler, /policyLease = await beginOfflineDownloadPolicyLease\([\s\S]+const policyRefresh = policyLease\.refresh\(\);[\s\S]+catalog = serverCatalogSnapshot/);
  assert.match(serverSyncHandler, /downloadSavedSourceSong\([\s\S]+signal: policyLease\.signal[\s\S]+finalizeAuthorization: async \(\) => \{[\s\S]+await policyRefresh;[\s\S]+policyLease\.assertAuthorized\(\)/);
  assert.match(serverSyncHandler, /retryServerDownload\(async \(\) => \{[\s\S]+policyLease\.signal\.throwIfAborted\(\)[\s\S]+signal: policyLease\.signal[\s\S]+await policyRefresh;[\s\S]+policyLease\.assertAuthorized\(\);[\s\S]+adoptDownloadedFile\(temporary, destination,[\s\S]+assertAuthorized: \(\) => policyLease\.assertAuthorized\(\)/);
  assert.doesNotMatch(serverSyncHandler, /const finalConfig = await requireOfflineDownloadMode/);
  assert.match(mediaRefreshHelper, /\.\.\.profileHeaders\(token, profileID\),[\s\S]+\.\.\.requestContext\.expected\.request_headers[\s\S]+redirect: "manual"/);
  const transferProgressBodies = [...mainSource.matchAll(/event\.sender\.send\("server:transfer-progress",\s*\{([\s\S]*?)\}\);/g)]
    .map((match) => match[1]);
  for (const body of transferProgressBodies) assert.match(body, /autoHide:\s*false/);
  assert.match(serverDownloadSource, /function serverDownloadProgressEvent[\s\S]+autoHide:\s*false/);
  assert.match(serverDownloadSource, /function createServerDownloadProgressPublisher[\s\S]+isInitial[\s\S]+isFinal[\s\S]+minimumInterval/);
  assert.match(mainSource, /function serverTransferIsActive\(event, controller, generation[\s\S]+active === controller[\s\S]+active\?\.resonanceGeneration === generation[\s\S]+controller\?\.signal\.aborted !== true/);
  assert.match(serverSyncHandler, /if \(!serverTransferIsActive\(event, controller, transferGeneration\)\) return;[\s\S]+event\.sender\.send\("server:transfer-progress", progressEvent\)/);
  assert.match(serverSyncHandler, /let itemTransferStarted = false;[\s\S]+if \(!itemTransferStarted\) return;[\s\S]+if \(itemCompletedBytes <= 0\) return;[\s\S]+itemTransferStarted = true/);
  assert.match(mainSource, /const imported = await importConfirmedSource\([\s\S]+options\.onProgress\?\.\(\{ stage: "transfer_complete" \}\);[\s\S]+await options\.finalizeAuthorization\?\.\(\)/);
  assert.match(serverSyncHandler, /\["transfer_complete", "processing", "saving_local", "local_complete"\][\s\S]+itemTotalBytes = itemTotalBytes \|\| itemCompletedBytes;[\s\S]+transferEnd\.autoHide = completed >= itemCount/);
  assert.match(serverSyncHandler, /event\.autoHide = completed >= itemCount && itemTotalBytes > 0 && itemCompletedBytes >= itemTotalBytes;/);
  assert.match(serverSyncHandler, /const resetItemTransfer = \(\) => \{[\s\S]+progressEvent\(\{ completedBytes: 0, totalBytes: itemTotalBytes \}\)[\s\S]+autoHide: false[\s\S]+itemTransferStarted = false;[\s\S]+itemCompletedBytes = 0;[\s\S]+publishProgress\.reset\(\)/);
  assert.doesNotMatch(serverSyncHandler, /direction: "download",[\s\S]{0,120}dismiss: true/);
  assert.match(serverSyncHandler, /onRetry: resetItemTransfer/);
  assert.match(serverSyncHandler, /\} catch \(error\) \{[\s\S]+resetItemTransfer\(\);[\s\S]+if \(error\?\.name === "AbortError"\) throw error;[\s\S]+failedByIndex\[pendingIndex\] =/);
  assert.match(serverSyncHandler, /completed \+= 1;[\s\S]+if \(itemSucceeded\) \{/);
  assert.doesNotMatch(serverSyncHandler, /title: `Retrying download|onRetry:[\s\S]{0,300}completedBytes: itemCompletedBytes|if \(itemSucceeded \|\| itemCompletedBytes > 0\)/);
  assert.match(serverDownloadSource, /publishProgress\.reset = \(\) => \{[\s\S]+lastPublishedAt = Number\.NEGATIVE_INFINITY;[\s\S]+publishedInitial = false;[\s\S]+publishedFinal = false/);
  assert.match(appSource, /if \(dismiss\) \{[\s\S]+hideServerTransfer\(owner\);[\s\S]+return;/);
  assert.doesNotMatch(serverSyncHandler, /completedBytes: itemCompletedBytes \|\| 1|totalBytes: itemTotalBytes \|\| itemCompletedBytes \|\| 1/);
  assert.doesNotMatch(appSource, /updateServerTransfer\(\{ direction: "download", currentFile: "Preparing download/);
  assert.doesNotMatch(appSource, /Preparing transfer|Preparing download/);
  assert.doesNotMatch(appSource, /await hydrateServerCatalogMetadata\(/);
  assert.doesNotMatch(htmlSource, /Preparing transfer|Preparing download|id="serverTransferPercent">0%<|id="serverTransferProgress"[^>]+value="0"/);
  assert.match(htmlSource, /id="serverTransferToast"[^>]+hidden[\s\S]+id="serverTransferTitle"><\/strong>[\s\S]+id="serverTransferDetail"><\/small>[\s\S]+id="serverTransferProgress" max="1"[\s\S]+id="serverTransferPercent"><\/span>/);
  assert.doesNotMatch(appSource, /direction === "download" && downloadBytes <= 0/);
  assert.match(serverSyncHandler, /downloadPresentation\.update\(pendingIndex, progressEvent\(\{\s+title: serverDownloadPreparationTitle\(savedSourceURL, "starting"\),\s+\}\)\)/);
  assert.match(serverSyncHandler, /const completedBatchResult = \(\) => serverDownloadBatchResultSnapshot\(\{[\s\S]+downloadedByIndex,[\s\S]+replacedTrackIDsByIndex,[\s\S]+failedByIndex/);
  assert.match(serverSyncHandler, /if \(error\?\.name === "AbortError"\) \{\s+return \{ catalog, \.\.\.completedBatchResult\(\), cancelled: true \};/);
  assert.match(appSource, /const displayedTransferComplete = itemTotal !== undefined[\s\S]+Number\(itemCompleted\) >= Number\(itemTotal\)/);
  assert.match(appSource, /const ownsVisibleDownload = serverTransferActive[\s\S]+if \(!ownsVisibleDownload && !\(stage === "downloading" && completed > 0\)\) return;/);
  assert.match(appSource, /if \(ownsVisibleDownload && stage === "downloading" && completed <= 0\) return;/);
  assert.match(appSource, /serverDownloadOperationActive = true;[\s\S]+await api\.syncServer\([\s\S]+finally \{[\s\S]+serverDownloadOperationActive = false;/);
  assert.match(downloadFileSource, /const \{ done, value \} = await reader\.read\(\);\s+signal\?\.throwIfAborted\(\);\s+if \(done\) break;/);
  assert.match(replaceServerCatalogBody, /resetServerCatalogAuthority\(\);[\s\S]+serverCatalogGeneration \+= 1/);
  assert.match(refreshServerCatalogAfterUploadBody, /replaceServerCatalog\(catalog\.songs\);\s+markServerCatalogAuthoritative\(context\);/);
  assert.doesNotMatch(rememberUploadedServerSongsBody, /markServerCatalogAuthoritative/);
  assert.match(preloadSource, /discardServerUploadRetries/);
  assert.match(preloadSource, /fetchClientConfig:[\s\S]+server:client-config/);
  assert.match(preloadSource, /importServerSource:[\s\S]+server:source-import/);
  assert.doesNotMatch(resolveLinkImportHandler, /localImportServerUploadMode === "server_source_link"[\s\S]+await confirmLinkImport\(\);[\s\S]+return;/);
  assert.match(resolveLinkImportHandler, /const reviewedDiscovery = localImportServerUploadMode === "reviewed_match"[\s\S]+reviewedContext = currentServerUploadContext\(\)[\s\S]+adminToken: reviewedContext\?\.adminToken \|\| ""/);
  assert.doesNotMatch(resolveLinkImportHandler, /adminToken: serverAdminToken/);
  assert.doesNotMatch(directSourceImportHandler, /resolveLocalImport|reviewed_match|candidate/);
  assert.match(directSourceImportHandler, /exactYouTubeSourcePageURL\(\$\("#localImportSource"\)\.value\)/);
  assert.match(directSourceImportHandler, /api\.importServerSource\(\{/);
  const directConfirmBranch = confirmLinkImportHandler.slice(0, confirmLinkImportHandler.indexOf("if (!localImportResolution) return;"));
  assert.doesNotMatch(directConfirmBranch, /confirmServerSourceImport\(\)/);
  assert.doesNotMatch(confirmLinkImportHandler, /requiresLocalFile: true/);
  assert.match(confirmLinkImportHandler, /api\.startLocalImport\(\{/);
  assert.match(confirmLinkImportHandler, /reviewedUpload[\s\S]+uploadReviewedMatchTrack\(importedTrack, importContext\)[\s\S]+uploadImportedTrackWithMode\(/);
  assert.match(confirmLinkImportHandler, /localImportServerUploadMode === "server_source_link" \? "server_source_link" : "local_file"/);

  assert.match(appSource, /data-remote-row="\$\{escapeHTML\(song\.id\)\}"/);
  assert.doesNotMatch(appSource, /data-remote-row="\$\{song\.id\}"/);
  assert.match(appSource, /summary\.localBytes/);
  assert.match(appSource, /Array\.isArray\(result\.failed\)/);
  assert.match(appSource, /serverUploadManifestMarkup\(\)[\s\S]+data-retry-upload-manifest/);
  assert.match(appSource, /physicalStorageClassForTrack\(track\)/);
  assert.match(appSource, /sourceIdentity: localImportSourceIdentity/);
  assert.match(appSource, /backfillLocalImportSourceIdentity\(duplicate, response\.result\.sourceIdentity\)/);
  assert.match(appSource, /function serverCatalogMatchForLocalImport\([\s\S]+contentSha256[\s\S]+content_sha256[\s\S]+return hashMatch \|\| null;/);
  assert.doesNotMatch(appSource, /serverSongMetadataMatches/);
  assert.match(appSource, /candidate\.fallbackCandidates\.filter\(localImportCandidateCanAutoSelect\)/);
  assert.match(appSource, /retainServerUploadManifest\(result, context, "link-import"\)/);
  assert.match(appSource, /function activateProfile\([\s\S]+checkpointListeningSessionForContextChange\(\)[\s\S]+storeActiveProfileState\(state\)[\s\S]+restoreProfileState\(state, profileID, serverURL\)[\s\S]+beginListeningSession\(\)/);
  assert.match(appSource, /response\.result\.serverBacked && response\.result\.remoteSong && importedTrack[\s\S]+requireTrackUploadAssociationContext\(importedTrack, importContext\)[\s\S]+reconcileUploadedTrack\(state, importedTrack\.id, response\.result\.remoteSong,[\s\S]+serverURL: importContext\.serverURL,[\s\S]+profileID: importContext\.profileID/);
  assert.match(appSource, /finishClipPlaybackIfNeeded\(\)[\s\S]+else if \(!move\(1\)\)[\s\S]+audio\.pause\(\)/);
  assert.match(appSource, /media\.onended = \(\) => \{[\s\S]+if \(repeat\)[\s\S]+finishListeningSessionForReplay\(\)[\s\S]+else if \(\$\("#installedVideoDialog"\)\.open && installedVideoSession\)[\s\S]+advanceInstalledVideo\(1\)/);
  assert.match(appSource, /context = currentProfileContext\(\)[\s\S]+api\.postListeningHistory\(\{[\s\S]+baseURL: context\.serverURL,[\s\S]+token: context\.token/);
  assert.match(appSource, /api\.fetchListeningHistory\(\{[\s\S]+profileID: context\.profileID[\s\S]+profileContextIsCurrent\(context\)[\s\S]+mergeListeningHistoryDocument\(state, remoteDocument, context\.profileID, context\.serverURL, serverCatalog\)/);
  assert.match(appSource, /row\.onkeydown = \(event\) => \{[\s\S]+event\.key === "Enter" \|\| event\.key === " "/);
  assert.match(appSource, /function bindRemoteRows\(\)[\s\S]+const activate = \(\) => \{[\s\S]+playRemoteStream\(song\)[\s\S]+row\.onclick = \(event\)[\s\S]+activate\(\)[\s\S]+row\.onkeydown/);
  assert.match(appSource, /button\.tabIndex = active \? 0 : -1/);
  assert.match(appSource, /\["ArrowLeft", "ArrowRight", "Home", "End"\]\.includes\(event\.key\)/);
  assert.match(appSource, /function focusSearchSortOption[\s\S]+\["ArrowDown", "ArrowUp", "Home", "End"\]\.includes\(event\.key\)/);
  assert.match(htmlSource, /class="full-player-queue-tabs" role="tablist"/);
  assert.match(htmlSource, /object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'/);
  assert.doesNotMatch(appSource, /id="serverUploadMode"|id="serverDownloadMode"|serverTransferModeHelp/);
  assert.match(htmlSource, /media-src 'self' file: blob: resonance-stream:/);
  assert.match(mainSource, /protocol\.registerSchemesAsPrivileged[\s\S]+standard: true,[\s\S]+secure: true,[\s\S]+stream: true/);
  assert.doesNotMatch(mainSource, /supportFetchAPI/);
  assert.match(mainSource, /protocol\.handle\(SERVER_STREAM_SCHEME, handleServerStreamRequest\)/);
  assert.match(mainSource, /ipcMain\.handle\("server:stream:create"[\s\S]+requireServerStreamMode\([\s\S]+force: true[\s\S]+fetchFreshStreamCatalogSong/);
  assert.match(mainSource, /ipcMain\.handle\("server:stream:release"[\s\S]+ownerWebContentsID !== event\.sender\.id/);
  assert.match(mainSource, /MAX_SERVER_STREAM_REQUESTS_PER_SESSION = 4[\s\S]+MAX_ACTIVE_SERVER_STREAM_REQUESTS = 32/);
  assert.match(mainSource, /handleServerStreamRequest\(request\)[\s\S]+parseSingleByteRange\(request\.headers\.get\("range"\)[\s\S]+profileHeaders\(session\.token, session\.profileID\)[\s\S]+requestContext\.expected\.request_headers[\s\S]+"Accept-Encoding": "identity"[\s\S]+redirect: "manual"[\s\S]+validateStreamResponse\([\s\S]+createExactLengthRelay/);
  assert.match(mainSource, /serverStreamErrorResponse[\s\S]+safeStatus === 416[\s\S]+Content-Range/);
  assert.match(mainSource, /session\.expirationTimer = setTimeout\(\(\) => revokeServerStreamSession\(sessionID\), SERVER_STREAM_SESSION_TTL_MS\)/);
  assert.match(mainSource, /function revokeServerStreamSession[\s\S]+for \(const controller of session\.controllers\) controller\.abort\(\)/);
  assert.match(mainSource, /if \(previousFingerprint !== nextFingerprint\) \{[\s\S]+rendererCredentialEpochs\.set[\s\S]+revokeServerStreamsForOwner\(event\.sender\.id\)/);
  assert.match(mainSource, /function persistableLibraryTrack[\s\S]+track\.transientStream !== true[\s\S]+SERVER_STREAM_SCHEME/);
  assert.match(mainSource, /currentFloorSafeCachedConfig\([\s\S]+validCachedClientConfig\(record,[\s\S]+clientConfigRevisionFloor\(context\.stored, cacheKey\)[\s\S]+commitClientConfigRecord\(/);
  assert.match(mainSource, /Object\.entries\(value\.revision_floors\)\.filter/);
  assert.doesNotMatch(mainSource, /revision_floors\)\.slice|stored\.revision_floors = Object\.fromEntries/);
  assert.match(preloadSource, /createServerStream:[\s\S]+server:stream:create[\s\S]+releaseServerStream:[\s\S]+server:stream:release/);
  const remoteStreamPlayback = appSource.slice(
    appSource.indexOf("async function playRemoteStream(song)"),
    appSource.indexOf("function currentServerUploadContext()"),
  );
  assert.match(remoteStreamPlayback, /id: `stream:\$\{crypto\.randomUUID\(\)\}`/);
  assert.match(remoteStreamPlayback, /transientStream: true/);
  assert.doesNotMatch(remoteStreamPlayback, /state\.tracks\.(?:push|unshift|splice)/);
  assert.match(appSource, /const requiresDownload = serverSongRequiresDownload\(song\);[\s\S]+disabled: !offlineDownloadAvailable && requiresDownload/);
  assert.match(appSource, /state\.currentTrackID = track\.transientStream \? null : currentID/);
  assert.match(appSource, /const historyTrackID = track\.transientStream \? track\.historyTrackID : track\.id[\s\S]+trackID: historyTrackID[\s\S]+remoteID: track\.remoteID \|\| null/);
  const listeningEntry = appSource.slice(
    appSource.indexOf("  const entry = {", appSource.indexOf("function beginListeningSession()")),
    appSource.indexOf("  state.listeningHistory =", appSource.indexOf("function beginListeningSession()")),
  );
  assert.doesNotMatch(listeningEntry, /fileUrl|streamURL/);
  assert.match(appSource, /function scheduleClientConfigRenewal\(\)[\s\S]+clientConfigRenewalDelay\(clientConfig\)[\s\S]+refreshClientConfig\(\{ force: true \}\)/);
  assert.match(appSource, /async function retryServerUploadManifest[\s\S]+currentServerUploadContext\(\)[\s\S]+adminToken: context\.adminToken[\s\S]+serverUploadContextIsCurrent\(context\)/);
  assert.match(appSource, /async function uploadServerSongs[\s\S]+currentServerUploadContext\(\)[\s\S]+adminToken: context\.adminToken[\s\S]+serverUploadContextIsCurrent\(context\)/);
  assert.match(appSource, /async function uploadMissingDownloadedSongs[\s\S]+currentServerUploadContext\(\)[\s\S]+adminToken: context\.adminToken[\s\S]+serverUploadContextIsCurrent\(context\)/);

  for (const filename of [
    "crash-safe-file.cjs",
    "download-file.cjs",
    "filename-policy.cjs",
    "provenance.cjs",
    "server-policy.cjs",
    "server-request.cjs",
    "account-avatar.cjs",
    "client-config.cjs",
    "client-config-state.cjs",
    "listening-history.cjs",
    "policy-lease.cjs",
    "server-stream.cjs",
    "server-upload-response.cjs",
    "response-body.cjs",
    "updater-auth.cjs",
  ]) assert.ok(packageJSON.build.files.includes(filename), `${filename} must ship in packaged builds`);
});
