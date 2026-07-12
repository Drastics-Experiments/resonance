import assert from "node:assert/strict";
import test from "node:test";
import { createEmptyState, filterTracks, formatTime, mergeSyncedTracks, nextIndex, normalizeState, tracksForPlaylist } from "../ui/core.js";

test("normalizes Liked Songs from favorites only", () => {
  const state = normalizeState({ tracks: [{ id: "a" }, { id: "b" }], playlists: [], favorites: ["b"] });
  assert.deepEqual(state.playlists[0].trackIDs, ["b"]);
  assert.equal(state.playlists[0].isSystem, true);
});

test("search, queue movement, playlists, and time formatting work", () => {
  const tracks = [
    { id: "a", title: "Glass", artist: "Local", album: "Sounds", filePath: "C:\\Music\\glass.mp3", dateAdded: "2026-01-01T00:00:00Z" },
    { id: "b", title: "Ping", artist: "Server", album: "Remote", filePath: "C:\\Music\\ping.mp4", dateAdded: "2026-02-01T00:00:00Z" },
  ];
  assert.deepEqual(filterTracks(tracks, "remote").map((track) => track.id), ["b"]);
  assert.deepEqual(filterTracks(tracks, "", "audio").map((track) => track.id), ["a"]);
  assert.deepEqual(filterTracks(tracks, "", "recent").map((track) => track.id), ["b", "a"]);
  assert.equal(nextIndex(tracks, "a", 1), 1);
  assert.equal(nextIndex(tracks, "a", -1), 1);
  assert.equal(nextIndex(tracks, "a", 1, true, () => 0), 1);
  assert.equal(formatTime(222), "3:42");
  const state = createEmptyState();
  state.tracks = tracks;
  state.playlists.push({ id: "p", name: "Test", trackIDs: ["b"], isSystem: false });
  assert.deepEqual(tracksForPlaylist(state, "p").map((track) => track.id), ["b"]);
});

test("replaces stale synced tracks instead of discarding the fresh download", () => {
  const state = createEmptyState();
  state.tracks = [{ id: "stale", remoteID: "remote-1" }, { id: "local" }];
  state.favorites = ["stale"];
  state.playlists.push({ id: "mix", name: "Mix", trackIDs: ["stale", "local"], isSystem: false });
  mergeSyncedTracks(state, {
    replacedTrackIDs: ["stale"],
    downloaded: [{ id: "stale", remoteID: "remote-1", title: "Fresh copy" }],
  });
  assert.deepEqual(state.tracks.map((track) => track.id), ["local", "stale"]);
  assert.deepEqual(state.favorites, ["stale"]);
  assert.deepEqual(state.playlists.find((playlist) => playlist.id === "mix").trackIDs, ["stale", "local"]);
});
