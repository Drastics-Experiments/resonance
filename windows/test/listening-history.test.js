import assert from "node:assert/strict";
import test from "node:test";
import listeningHistory from "../listening-history.cjs";

const { normalizeListeningHistoryEntry, normalizeListeningHistoryUploadEntries } = listeningHistory;

test("serializes local-only listening history as a bounded track snapshot", () => {
  const result = normalizeListeningHistoryEntry({
    id: "event-local",
    trackID: "windows-local-track",
    startedAt: "2026-08-16T12:00:00-05:00",
    listenedSeconds: 42.5,
    title: "Local song",
    artist: "Local artist",
    album: "Local album",
    duration: 240,
    filePath: "C:\\Users\\secret\\song.m4a",
  });

  assert.deepEqual(result, {
    id: "event-local",
    track_id: "windows-local-track",
    song_id: null,
    started_at: "2026-08-16T17:00:00.000Z",
    listened_seconds: 42.5,
    title: "Local song",
    artist: "Local artist",
    album: "Local album",
    duration_seconds: 240,
  });
  assert.equal(JSON.stringify(result).includes("secret"), false);
});

test("preserves an optional server song identity while retaining metadata", () => {
  const [result] = normalizeListeningHistoryUploadEntries([{
    id: "event-linked",
    track_id: "windows-copy",
    song_id: "server-song",
    started_at: "2026-08-16T12:00:00.000Z",
    listened_seconds: 20.01,
    duration_seconds: 200,
  }]);

  assert.equal(result.track_id, "windows-copy");
  assert.equal(result.song_id, "server-song");
  assert.equal(result.duration_seconds, 200);
});

test("bounds listening history snapshots without requiring a song ID", () => {
  assert.throws(() => normalizeListeningHistoryEntry({
    id: "missing-track",
    started_at: "2026-08-16T12:00:00.000Z",
    listened_seconds: 21,
  }), /track_id/);
  assert.throws(() => normalizeListeningHistoryEntry({
    id: "bad-duration",
    track_id: "local",
    started_at: "2026-08-16T12:00:00.000Z",
    listened_seconds: 21,
    duration: -1,
  }), /duration_seconds/);
  assert.throws(() => normalizeListeningHistoryUploadEntries([]), /between 1 and 500/);
});
