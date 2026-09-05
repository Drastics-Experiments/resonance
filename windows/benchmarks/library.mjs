import assert from "node:assert/strict";
import { performance } from "node:perf_hooks";
import { createEmptyState, filterPlaylists, tracksForPlaylist } from "../ui/core.js";
import asyncWork from "../async-work.cjs";

// Synthetic, device-local data only. Timings are diagnostic, not CI thresholds.
const state = createEmptyState();
state.tracks = Array.from({ length: 10_000 }, (_, index) => ({
  id: `track-${index}`,
  title: `Song ${index}`,
  artist: `Artist ${index % 100}`,
  album: `Album ${index % 500}`,
}));
state.playlists = Array.from({ length: 100 }, (_, index) => ({
  id: `playlist-${index}`,
  name: `Playlist ${index}`,
  isSystem: false,
  trackIDs: Array.from({ length: 100 }, (_, offset) => `track-${index * 100 + offset}`),
}));
const largePlaylist = {
  id: "large",
  name: "Large playlist",
  isSystem: false,
  trackIDs: state.tracks.filter((_, index) => index % 2 === 0).map((track) => track.id),
};
state.playlists.push(largePlaylist);

function previousPlaylistSearch(query) {
  return state.playlists.filter((playlist) => playlist.name.toLocaleLowerCase().includes(query)
    || playlist.trackIDs.some((id) => {
      const track = state.tracks.find((candidate) => candidate.id === id);
      return [track?.title, track?.artist, track?.album]
        .some((value) => String(value || "").toLocaleLowerCase().includes(query));
    }));
}

function measure(operation) {
  operation();
  const samples = Array.from({ length: 5 }, () => {
    const start = performance.now();
    operation();
    return performance.now() - start;
  });
  return Number(samples.sort((a, b) => a - b)[2].toFixed(2));
}

const previousOrder = () => largePlaylist.trackIDs
  .map((id) => state.tracks.find((track) => track.id === id)).filter(Boolean);
const indexedOrder = () => tracksForPlaylist(state, largePlaylist.id);
const previousSearch = () => previousPlaylistSearch("no matching song");
const indexedSearch = () => filterPlaylists(state.playlists, state.tracks, "no matching song");
assert.deepEqual(indexedOrder(), previousOrder());
assert.deepEqual(indexedSearch(), previousSearch());

let writes = 0;
const firstWrite = Promise.withResolvers();
const save = asyncWork.createLatestValueWriter(async () => {
  if (++writes === 1) await firstWrite.promise;
});
const firstSave = save({ version: 0 });
await new Promise(setImmediate);
const pendingSaves = Array.from({ length: 1_000 }, (_, version) => save({ version: version + 1 }));
firstWrite.resolve();
await Promise.all([firstSave, ...pendingSaves]);
assert.equal(writes, 2);

process.stdout.write(`${JSON.stringify({
  tracks: state.tracks.length,
  playlists: state.playlists.length,
  orderedPlaylistTracks: largePlaylist.trackIDs.length,
  medianMilliseconds: {
    playlistOrder: { previous: measure(previousOrder), indexed: measure(indexedOrder) },
    playlistSearch: { previous: measure(previousSearch), indexed: measure(indexedSearch) },
  },
  saveBurst: { requests: 1_001, writes },
}, null, 2)}\n`);
