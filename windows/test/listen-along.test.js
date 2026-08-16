import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import listenAlong from "../listen-along.cjs";

const {
  canonicalListenAlongCode,
  canonicalListenAlongMediaKind,
  canonicalListenAlongPosition,
  canonicalListenAlongRevision,
  canonicalListenAlongSnapshot,
  canonicalListenAlongSource,
  isNewerListenAlongRevision,
  normalizeListenAlongResponse,
  projectListenAlongPosition,
} = listenAlong;

const SOURCE = "https://www.youtube.com/watch?v=dQw4w9WgXcQ";

test("canonicalizes room codes and accepts only safe HTTPS source pages", () => {
  assert.equal(canonicalListenAlongCode(" abcd-1234 "), "ABCD-1234");
  assert.equal(canonicalListenAlongSource(SOURCE), SOURCE);
  assert.equal(canonicalListenAlongSource("https://Example.test/music?timestamp=12"), "https://example.test/music?timestamp=12");
  assert.equal(canonicalListenAlongSource(null), null);

  for (const invalid of [
    "http://example.test/music",
    "https://user:secret@example.test/music",
    "https://example.test/music#fragment",
    "https://r1---sn.googlevideo.com/videoplayback",
    "https://cdn.spotifycdn.com/audio.mp3",
    "https://127.0.0.1:8787/source",
    "https://music.local/source",
  ]) {
    assert.throws(() => canonicalListenAlongSource(invalid), /source|HTTPS|temporary/i);
  }
  for (const invalid of ["", "a/b", "-abcd", "a".repeat(65)]) {
    assert.throws(() => canonicalListenAlongCode(invalid), /code/i);
  }
});

test("normalizes the complete snapshot and bounds media state", () => {
  assert.equal(canonicalListenAlongMediaKind("audio"), "audio");
  assert.equal(canonicalListenAlongMediaKind("video"), "video");
  assert.equal(canonicalListenAlongPosition(12.34567), 12.346);
  assert.equal(canonicalListenAlongRevision("4"), 4);
  assert.deepEqual(canonicalListenAlongSnapshot({
    source_url: SOURCE,
    media_kind: "video",
    position_seconds: 12.34567,
    is_playing: true,
  }), {
    source_url: SOURCE,
    media_kind: "video",
    position_seconds: 12.346,
    is_playing: true,
  });
  assert.throws(() => canonicalListenAlongMediaKind("stream"), /audio or video/i);
  assert.throws(() => canonicalListenAlongPosition(-1), /position/i);
  assert.throws(() => canonicalListenAlongRevision(1.5), /revision/i);
  assert.throws(() => canonicalListenAlongSnapshot({
    source_url: null,
    media_kind: "audio",
    position_seconds: 0,
    is_playing: true,
  }), /source link/i);
});

test("accepts nested and legacy flat responses while preserving the room contract", () => {
  const nested = normalizeListenAlongResponse({
    schema_version: 1,
    formatted_code: "room-1234",
    role: "guest",
    revision: 4,
    snapshot: {
      source_url: SOURCE,
      media_kind: "audio",
      position_seconds: 37.5,
      is_playing: true,
    },
    updated_at: "2026-08-15T12:00:00.000Z",
    expires_at: "2026-08-15T20:00:00.000Z",
    server_time: "2026-08-15T12:00:01.000Z",
  }, { role: "guest" });
  assert.equal(nested.code, "ROOM-1234");
  assert.equal(nested.revision, 4);
  assert.equal(nested.snapshot.source_url, SOURCE);
  assert.equal(nested.server_time_ms, Date.parse("2026-08-15T12:00:01.000Z"));

  const flat = normalizeListenAlongResponse({
    code: "flat-1234",
    revision: 5,
    source_url: SOURCE,
    media_kind: "audio",
    position_seconds: 8,
    is_playing: false,
  }, { role: "host" });
  assert.equal(flat.code, "FLAT-1234");
  assert.equal(flat.role, "host");
  assert.equal(flat.snapshot.position_seconds, 8);
  assert.equal(flat.snapshot.is_playing, false);
  assert.throws(() => normalizeListenAlongResponse({
    schema_version: 2,
    code: "flat-1234",
    role: "guest",
  }), /unsupported protocol/i);
});

test("projects server-time playback and rejects stale revisions", () => {
  const serverTime = "2026-08-15T12:00:00.000Z";
  assert.equal(projectListenAlongPosition({
    source_url: SOURCE,
    media_kind: "audio",
    position_seconds: 12,
    is_playing: true,
  }, serverTime, Date.parse("2026-08-15T12:00:02.250Z")), 14.25);
  assert.equal(projectListenAlongPosition({
    source_url: SOURCE,
    media_kind: "audio",
    position_seconds: 12,
    is_playing: true,
  }, "2026-08-15T12:00:05.000Z", Date.parse("2026-08-15T12:00:02.250Z"), serverTime), 17);
  assert.equal(projectListenAlongPosition({
    source_url: SOURCE,
    media_kind: "audio",
    position_seconds: 12,
    is_playing: false,
  }, serverTime, Date.parse("2026-08-15T12:00:02.250Z")), 12);
  assert.equal(isNewerListenAlongRevision(5, 4), true);
  assert.equal(isNewerListenAlongRevision(4, 4), false);
  assert.equal(isNewerListenAlongRevision("invalid", 4), false);
});

test("keeps listen-along network and provider capabilities out of the renderer", async () => {
  const [main, preload, renderer, index, packageJSON] = await Promise.all([
    readFile(new URL("../main.cjs", import.meta.url), "utf8"),
    readFile(new URL("../preload.cjs", import.meta.url), "utf8"),
    readFile(new URL("../ui/app.js", import.meta.url), "utf8"),
    readFile(new URL("../ui/index.html", import.meta.url), "utf8"),
    readFile(new URL("../package.json", import.meta.url), "utf8"),
  ]);
  assert.match(main, /X-Resonance-Listen-Host/);
  assert.match(main, /canonicalListenAlongSnapshot\(settings\.snapshot \|\| settings, \{ sourceRequired: true \}\)/);
  assert.match(main, /error\?\.status !== 409 \|\| conflictRetry/);
  assert.match(main, /refreshListenAlongSession\(session\)/);
  assert.match(main, /putRevision = session\.revision/);
  assert.match(main, /listen-along:source:create/);
  assert.match(main, /importConfirmedSource/);
  assert.match(main, /fileUrl: pathToFileURL\(imported\.filePath\)\.href/);
  assert.match(main, /source_key/);
  assert.match(main, /LISTEN_ALONG_POLL_INTERVAL_MS = 250/);
  assert.match(main, /session\.role !== "guest"\) return;/);
  assert.match(main, /listenAlongMediaPending/);
  assert.match(main, /pending\.waiters \+= 1/);
  assert.match(main, /leases: 1 \+ pendingRecord\.waiters/);
  assert.match(main, /media\.leases -= 1/);
  assert.match(main, /forceReleaseListenAlongMediaSession/);
  assert.match(main, /clipboard\.writeText\(code\)/);
  assert.match(main, /ipcMain\.handle\("listen-along:copy-code"/);
  assert.match(main, /listenAlongTrustedRenderer\(event\.sender\)/);
  assert.match(preload, /listen-along:create/);
  assert.match(preload, /listen-along:source:release/);
  assert.match(preload, /copyListenAlongCode: \(code\) => ipcRenderer\.invoke\("listen-along:copy-code", code\)/);
  assert.match(renderer, /api\.createListenAlongSource/);
  assert.match(renderer, /api\.copyListenAlongCode/);
  assert.match(renderer, /copyListenAlongRoomCode/);
  assert.match(renderer, /\$\("#openListenAlong"\)\.onclick = openListenAlongDialog/);
  assert.match(renderer, /event\.server_time/);
  assert.match(renderer, /event\.updated_at/);
  assert.match(renderer, /revision <= session\.revision && session\.hasEvent/);
  assert.match(renderer, /activeListenAlongStream\?\.sessionID === session\.id/);
  assert.match(renderer, /localTrackForListenAlongSource\(event\.source_key\)/);
  assert.match(renderer, /currentServerTransferModes\(\)\.downloadMode === "stream_only"/);
  assert.match(renderer, /if \(!track\) \{\s*const capability = await api\.createListenAlongSource/);
  assert.match(renderer, /hydrateListenAlongArtwork/);
  assert.match(renderer, /api\.fetchLocalImportArtwork\(source\)/);
  assert.match(renderer, /!\/\^file:/i);
  assert.doesNotMatch(renderer, /audio\.src\s*=\s*event\??\.snapshot\??\.source_url/);
  assert.match(index, /connect-src 'none'/);
  assert.match(index, /media-src[^;]*file:/);
  assert.match(index, /id="openListenAlong"[^>]*>[^<]*<svg[^>]*class="transport-icon"/);
  assert.match(index, /id="copyListenAlongCode"[^>]*disabled/);
  assert.match(index, /id="listenAlongCopyFeedback"[^>]*aria-live="polite"/);
  assert.match(index, /id="listenAlongStatus">Not connected<\/span>/);
  assert.match(index, /id="copyListenAlongCode"[^>]*class="secondary listen-along-copy"/);
  assert.match(renderer, /\$\("#copyListenAlongCode"\)\.onclick = \(\) => \{ void copyListenAlongRoomCode\(\); \}/);
  assert.match(await readFile(new URL("../ui/styles.css", import.meta.url), "utf8"), /#listenAlongStatus/);
  assert.match(packageJSON, /"listen-along\.cjs"/);
});
