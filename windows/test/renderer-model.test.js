import assert from "node:assert/strict";
import test from "node:test";
import { createEmptyState, createRendererModel, createListeningHistoryIndex, summarizeListeningStats, hydrateRemotePlaylistTracks, hydrateRemoteLikedTracks, playbackTracksForIDs, tracksForPlaylist, updatePlaylistRemoteSongIDs } from "../ui/core.js";

test("history indexing preserves ambiguous metadata matches and observes later edits", () => {
  const state = createEmptyState();
  state.serverURL = "https://music.example";
  state.tracks = [
    { id: "first", title: "Café", artist: "A & B", duration: 200, filePath: "/fixture/first.mp3" },
    { id: "second", title: "Cafe", artist: "B and A", duration: 202, filePath: "/fixture/second.mp3" },
  ];
  state.listeningHistory = [{ id: "entry", trackID: "old-id", title: "Cafe", artist: "A with B", duration: 201,
    listenedSeconds: 21, profileID: "default", serverOrigin: state.serverURL, startedAt: "2026-09-04T12:00:00Z" }];
  const now = new Date("2026-09-04T13:00:00Z");
  const ambiguous = summarizeListeningStats(state, now, createListeningHistoryIndex(state));
  assert.equal(ambiguous.topTrackID, "old-id");
  assert.equal(ambiguous.plays, 1);
  state.tracks.pop();
  assert.equal(summarizeListeningStats(state, now).topTrackID, "first");
  state.listeningHistory[0].trackID = "first";
  state.tracks[0].duration = 300;
  assert.equal(summarizeListeningStats(state, now).plays, 0);
});

test("synced playlist and like hydration preserve local order and active remote identity", () => {
  const state = createEmptyState();
  state.serverURL = "https://music.example";
  state.tracks = [
    { id: "wrong-profile", remoteID: "song", sourceServer: state.serverURL, syncProfileID: "other" },
    { id: "wrong-server", remoteID: "song", sourceServer: "https://other.example" },
    { id: "local" },
    { id: "first", remoteID: "song", sourceServer: state.serverURL },
    { id: "second", remoteID: "song", sourceServer: state.serverURL },
  ];
  state.playlists.push({ id: "mix", trackIDs: ["local", "first"], remoteSongIDs: ["song", "unresolved"] });
  state.favorites = ["local", "wrong-profile", "wrong-server"];
  state.remoteLikedSongIDs = ["song"];
  hydrateRemotePlaylistTracks(state);
  hydrateRemoteLikedTracks(state);
  assert.deepEqual(state.playlists.at(-1).trackIDs, ["local", "first"]);
  assert.deepEqual(state.playlists.at(-1).remoteSongIDs, ["song", "unresolved"]);
  assert.deepEqual(state.favorites, ["local", "first", "second"]);
  assert.deepEqual(state.playlists[0].trackIDs, state.favorites);
  state.syncProfileID = "other";
  hydrateRemotePlaylistTracks(state);
  hydrateRemoteLikedTracks(state);
  assert.deepEqual(state.playlists.at(-1).trackIDs, ["local", "wrong-profile"]);
  assert.deepEqual(state.favorites, ["local", "wrong-profile"]);
});

test("playlist render snapshots see new membership and catalog metadata on the next render", () => {
  const state = createEmptyState();
  const catalog = [{ id: "song", title: "Original" }];
  state.playlists.push({ id: "mix", trackIDs: [], remoteSongIDs: ["song"] });
  const first = createRendererModel(state, catalog);
  assert.equal(tracksForPlaylist(state, "mix", catalog, first)[0].title, "Original");
  catalog[0].title = "Updated";
  state.tracks.push({ id: "local", title: "Local" });
  state.playlists.at(-1).trackIDs.push("local");
  const next = createRendererModel(state, catalog);
  assert.deepEqual(tracksForPlaylist(state, "mix", catalog, next).map((track) => track.title), ["Local", "Updated"]);
});

test("playlist membership preserves unresolved songs and first active matches across profile changes", () => {
  const state = createEmptyState();
  state.serverURL = "https://music.example";
  const remote = (id, remoteID, syncProfileID = "default") => ({ id, remoteID, syncProfileID, sourceServer: state.serverURL });
  state.tracks = [
    remote("duplicate", "other-profile", "other"),
    remote("duplicate", "first"),
    remote("duplicate", "second"),
    remote("removed", "removed"),
    { id: "local" },
  ];
  const playlist = {
    trackIDs: ["duplicate", "local", "missing", "duplicate"],
    remoteSongIDs: ["first", "unresolved", "removed", "other-profile"],
  };
  updatePlaylistRemoteSongIDs(state, playlist);
  assert.deepEqual(playlist.remoteSongIDs, ["first", "unresolved", "other-profile"]);
  state.syncProfileID = "other";
  updatePlaylistRemoteSongIDs(state, playlist);
  assert.deepEqual(playlist.remoteSongIDs, ["first", "unresolved", "other-profile"]);
});

test("indexed playback preserves queue order, duplicate IDs, active scope, and stream precedence", () => {
  const state = createEmptyState();
  state.serverURL = "https://music.example";
  state.tracks = [
    { id: "same", remoteID: "remote", sourceServer: state.serverURL, syncProfileID: "other" },
    { id: "same", title: "First active" },
    { id: "same", title: "Second active" },
    { id: "unavailable", available: false },
  ];
  const stream = { id: "stream", transientStream: true };
  const queue = ["stream", "same", "absent", "same", "unavailable"];
  assert.deepEqual(playbackTracksForIDs(state, queue, [null, stream, { id: "same" }, { id: "stream" }]),
    [stream, state.tracks[1], state.tracks[1], state.tracks[3]]);
  state.tracks.splice(1, 1);
  assert.equal(playbackTracksForIDs(state, ["same"])[0].title, "Second active");
});

test("renderer model indexes local and server songs while scoping device membership to the active profile", () => {
  const state = createEmptyState();
  state.serverURL = "https://resonance.example";
  state.syncProfileID = "profile-a";
  state.tracks = [
    { id: "local", title: "Local", remoteID: null },
    {
      id: "active-remote",
      title: "Active remote",
      remoteID: "song-1",
      sourceServer: state.serverURL,
      syncProfileID: "profile-a",
    },
    {
      id: "other-remote",
      title: "Other profile",
      remoteID: "song-1",
      sourceServer: state.serverURL,
      syncProfileID: "profile-b",
    },
  ];
  state.playlists.push({ id: "mix", name: "Mix", trackIDs: ["local"], isSystem: false });
  const catalog = [
    { id: "song-1", title: "Active remote" },
    { id: "song-2", title: "Another song" },
  ];
  const model = createRendererModel(state, catalog);

  assert.equal(model.tracksByID.get("local")?.title, "Local");
  assert.deepEqual(model.activeTracks.map((track) => track.id), ["local", "active-remote"]);
  assert.equal(model.catalogByID.get("song-2")?.title, "Another song");
});

test("renderer model keeps first-match behavior for duplicate identifiers", () => {
  const state = createEmptyState();
  state.tracks = [{ id: "duplicate", title: "First" }, { id: "duplicate", title: "Second" }];
  const catalog = [{ id: "song", title: "First" }, { id: "song", title: "Second" }];
  const model = createRendererModel(state, catalog);

  assert.equal(model.tracksByID.get("duplicate")?.title, "First");
  assert.equal(model.catalogByID.get("song")?.title, "First");
});

test("a new render model observes in-place library and profile mutations", () => {
  const state = createEmptyState();
  state.serverURL = "https://resonance.example";
  state.syncProfileID = "profile-a";
  state.tracks = [{
    id: "remote",
    title: "Original",
    remoteID: "song-a",
    sourceServer: state.serverURL,
    syncProfileID: "profile-a",
  }];
  const first = createRendererModel(state, [{ id: "song-a", title: "Original" }]);

  // Mutations are intentionally allowed between renders. The renderer builds a
  // fresh snapshot at the next render boundary instead of trying to guess
  // which event handler changed which collection.
  state.syncProfileID = "profile-b";
  state.tracks[0].remoteID = "song-b";
  state.tracks.push({ id: "new", title: "New" });
  const second = createRendererModel(state, [{ id: "song-b", title: "Updated" }]);

  assert.equal(first.activeTracks[0]?.id, "remote");
  assert.deepEqual(second.activeTracks.map((track) => track.id), ["new"]);
  assert.equal(second.tracksByID.get("new")?.title, "New");
});

test("indexed playlist hydration matches the fallback for duplicate catalog IDs", () => {
  const state = createEmptyState();
  state.serverURL = "https://resonance.example";
  state.playlists.push({
    id: "remote-mix",
    name: "Remote mix",
    trackIDs: [],
    remoteSongIDs: ["song-1"],
    entryOrder: [],
    isSystem: false,
  });
  const catalog = [
    { id: "song-1", title: "First catalog title", artist: "First artist" },
    { id: "song-1", title: "Later catalog title", artist: "Later artist" },
  ];
  const model = createRendererModel(state, catalog);
  const fallback = tracksForPlaylist(state, "remote-mix", catalog);
  const indexed = tracksForPlaylist(state, "remote-mix", catalog, model);

  assert.deepEqual(indexed, fallback);
  assert.equal(indexed[0]?.title, "First catalog title");
  assert.equal(indexed[0]?.artist, "First artist");
});

test("indexed playlist lookup preserves strict ID matching and duplicate local membership", () => {
  const state = createEmptyState();
  state.tracks = [
    { id: 1, title: "Numeric ID" },
    { id: "1", title: "First string ID" },
    { id: "1", title: "Second string ID" },
  ];
  state.playlists.push({ id: "mix", trackIDs: ["1", 1, "missing", "1"], isSystem: false });
  const catalog = [];
  const indexed = tracksForPlaylist(state, "mix", catalog, createRendererModel(state, catalog));

  assert.deepEqual(indexed, tracksForPlaylist(state, "mix", catalog));
  assert.deepEqual(indexed.map((track) => track.title), ["First string ID", "Numeric ID", "First string ID"]);
});
