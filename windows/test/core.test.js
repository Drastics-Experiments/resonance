import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  applyRemotePlaylistDocument,
  createEmptyState,
  filterPlaylists,
  filterTracks,
  formatTime,
  mergePlaylistDocument,
  mergeSyncedTracks,
  nextIndex,
  normalizedVolume,
  normalizeState,
  tracksForPlaylist,
  updatePlaylistRemoteSongIDs,
} from "../ui/core.js";
import metadata from "../metadata.cjs";
import updaterFeed from "../updater-feed.cjs";

const { conciseUpdaterError, resolveWindowsUpdateFeed } = updaterFeed;

test("keeps contextual search and sorting in the persistent top bar", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  const preloadSource = readFileSync(new URL("../preload.cjs", import.meta.url), "utf8");
  assert.match(htmlSource, /id="searchSort"/);
  assert.match(htmlSource, /id="searchSortMenu"[\s\S]+role="listbox"/);
  assert.doesNotMatch(htmlSource, /<select id="searchSort"/);
  assert.doesNotMatch(appSource, /id="(?:storageSearch|serverSearch)"/);
  assert.match(appSource, /section === "storage"[\s\S]+updateSearchSort\([\s\S]+storageSort/);
  assert.match(appSource, /section === "server"[\s\S]+updateSearchSort\([\s\S]+serverSort/);
  assert.match(appSource, /class="server-status-line"/);
  assert.match(appSource, /class="server-library-bar"/);
  assert.match(appSource, /class="server-table-head/);
  assert.match(htmlSource, /id="serverTransferToast"/);
  assert.match(htmlSource, /id="dismissServerTransfer"/);
  assert.match(htmlSource, /id="dismissServerTransfer"[^>]+aria-label="Cancel transfer"/);
  assert.match(htmlSource, /id="appNotice"[^>]+aria-live="polite"/);
  assert.match(htmlSource, /id="seek"[^>]+aria-label="Playback position"/);
  assert.match(htmlSource, /id="volume"[^>]+aria-label="Volume"/);
  assert.match(htmlSource, /id="shuffle"[^>]+aria-pressed="false"/);
  assert.doesNotMatch(appSource, /<div id="serverTransferToast"/);
  assert.match(appSource, /function hideServerTransfer\(\)/);
  assert.match(appSource, /#dismissServerTransfer"\)\.onclick = cancelServerTransfer/);
  assert.match(preloadSource, /cancelServerTransfer:[\s\S]+server:cancel-transfer/);
  assert.match(mainSource, /new AbortController\(\)/);
  assert.match(mainSource, /server:cancel-transfer/);
  assert.match(mainSource, /signal\.throwIfAborted\(\)/);
  assert.match(mainSource, /library\.json\.corrupt-|\.corrupt-\$\{Date\.now\(\)\}/);
  assert.match(appSource, /function activePlaybackTracks\(\)/);
  assert.match(appSource, /function previous\(\)[\s\S]+recordHistory: false/);
  assert.match(appSource, /bindTrackRows\(tracks\)/);
  assert.match(appSource, /Alt\+ArrowUp Alt\+ArrowDown/);
  assert.doesNotMatch(appSource, /audio\.play\(\)\.catch\(\(error\) => console\.error/);
  assert.doesNotMatch(appSource, /class="connection-card"/);
  assert.match(appSource, /class="now-playing-icon"/);
  assert.doesNotMatch(appSource, /[Ⅱ▥]/);
  assert.match(mainSource, /autoUpdater\.logger\s*=\s*null/);
});

test("selects the newest stable release that actually has a Windows update feed", async () => {
  const fetchImpl = async () => ({
    ok: true,
    json: async () => [
      {
        tag_name: "android-v1.0.4",
        draft: false,
        prerelease: false,
        assets: [{ name: "Resonance-Android.apk", browser_download_url: "https://github.com/Drastics-Experiments/resonance/releases/download/android-v1.0.4/Resonance-Android.apk" }],
      },
      {
        tag_name: "v1.0.3",
        draft: false,
        prerelease: false,
        assets: [{ name: "latest.yml", browser_download_url: "https://github.com/Drastics-Experiments/resonance/releases/download/v1.0.3/latest.yml" }],
      },
    ],
  });

  assert.deepEqual(await resolveWindowsUpdateFeed(fetchImpl), {
    tag: "v1.0.3",
    feedURL: "https://github.com/Drastics-Experiments/resonance/releases/download/v1.0.3/",
  });
});

test("rejects release lists without a Windows manifest and shortens updater errors", async () => {
  const fetchImpl = async () => ({
    ok: true,
    json: async () => [{ tag_name: "android-v1.0.4", assets: [] }],
  });
  await assert.rejects(resolveWindowsUpdateFeed(fetchImpl), /No published Windows release/);
  assert.equal(
    conciseUpdaterError(new Error("Cannot find latest.yml: 404 Not Found\nvery long response headers and stack")),
    "The Windows update feed is temporarily unavailable.",
  );
});

test("converts embedded cover art into a renderable data URL", () => {
  assert.equal(metadata.pictureDataURL({ format: "image/png", data: Buffer.from([1, 2, 3]) }), "data:image/png;base64,AQID");
  assert.equal(metadata.pictureDataURL(null), null);
});

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
  assert.deepEqual(filterTracks(tracks, "glass.mp3").map((track) => track.id), ["a"]);
  assert.deepEqual(filterTracks(tracks, "", "audio").map((track) => track.id), ["a"]);
  assert.deepEqual(filterTracks(tracks, "", "recent").map((track) => track.id), ["b", "a"]);
  assert.equal(nextIndex(tracks, "a", 1), 1);
  assert.equal(nextIndex(tracks, "a", -1), 1);
  assert.equal(nextIndex(tracks, "a", 1, true, () => 0), 1);
  assert.equal(formatTime(222), "3:42");
  assert.equal(normalizedVolume(0), 0);
  assert.equal(normalizedVolume(2), 1);
  assert.equal(normalizedVolume("invalid"), 0.78);
  const state = createEmptyState();
  state.tracks = tracks;
  state.playlists.push({ id: "p", name: "Test", trackIDs: ["b"], isSystem: false });
  assert.deepEqual(tracksForPlaylist(state, "p").map((track) => track.id), ["b"]);
  assert.deepEqual(filterPlaylists(state.playlists, tracks, "ping").map((playlist) => playlist.id), ["p"]);
});

test("normalizes persisted playback context against the current library", () => {
  const state = normalizeState({
    tracks: [{ id: "a" }, { id: "b" }],
    playlists: [],
    favorites: [],
    playbackQueueIDs: ["b", "missing", "a", "b"],
    playbackPlaylistID: "playlist-1",
  });
  assert.deepEqual(state.playbackQueueIDs, ["b", "a"]);
  assert.equal(state.playbackPlaylistID, "playlist-1");
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

test("merges dirty local playlists over the server without deleting unrelated playlists", () => {
  const state = createEmptyState();
  state.tracks = [
    { id: "local-a", remoteID: "a".repeat(24) },
    { id: "local-only", remoteID: null },
  ];
  state.playlists.push({
    id: "12345678-1234-ABCD-9876-ABCDEF123456",
    name: "Windows order",
    trackIDs: ["local-a", "local-only"],
    remoteSongIDs: [],
    isSystem: false,
  });
  state.dirtyPlaylistIDs = ["12345678-1234-abcd-9876-abcdef123456"];
  const remote = {
    revision: 4,
    playlists: [{ id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", name: "Other device", song_ids: ["b".repeat(24)] }],
  };

  const merge = mergePlaylistDocument(state, remote);
  assert.equal(merge.needsUpload, true);
  assert.equal(merge.document.revision, 4);
  assert.deepEqual(merge.document.playlists.map((playlist) => playlist.name), ["Other device", "Windows order"]);
  assert.equal(merge.document.playlists[1].id, "12345678-1234-abcd-9876-abcdef123456");
  assert.deepEqual(merge.document.playlists[1].song_ids, ["a".repeat(24)]);
});

test("applies remote ordering, preserves local-only songs, and hydrates later downloads", () => {
  const playlistID = "12345678-1234-abcd-9876-abcdef123456";
  const firstRemoteID = "a".repeat(24);
  const secondRemoteID = "b".repeat(24);
  const state = createEmptyState();
  state.tracks = [
    { id: "downloaded-a", remoteID: firstRemoteID },
    { id: "local-only", remoteID: null },
  ];
  state.playlists.push({ id: playlistID, name: "Old", trackIDs: ["local-only"], remoteSongIDs: [], isSystem: false });

  applyRemotePlaylistDocument(state, {
    revision: 7,
    playlists: [{ id: playlistID.toUpperCase(), name: "Shared", song_ids: [secondRemoteID, firstRemoteID] }],
  });
  assert.equal(state.playlistRevision, 7);
  assert.deepEqual(state.playlists[1].trackIDs, ["downloaded-a", "local-only"]);
  assert.deepEqual(state.playlists[1].remoteSongIDs, [secondRemoteID, firstRemoteID]);

  mergeSyncedTracks(state, { downloaded: [{ id: "downloaded-b", remoteID: secondRemoteID }], replacedTrackIDs: [] });
  assert.deepEqual(state.playlists[1].trackIDs, ["downloaded-b", "downloaded-a", "local-only"]);
});

test("deletions remove only the matching known server playlist", () => {
  const removedID = "12345678-1234-abcd-9876-abcdef123456";
  const retainedID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
  const state = createEmptyState();
  state.knownRemotePlaylistIDs = [removedID, retainedID];
  state.deletedPlaylistIDs = [removedID];
  const merge = mergePlaylistDocument(state, {
    revision: 2,
    playlists: [
      { id: removedID, name: "Delete me", song_ids: [] },
      { id: retainedID, name: "Keep me", song_ids: [] },
    ],
  });
  assert.equal(merge.needsUpload, true);
  assert.deepEqual(merge.document.playlists.map((playlist) => playlist.id), [retainedID]);
});

test("removing a downloaded song updates remote membership while keeping unresolved songs", () => {
  const state = createEmptyState();
  state.tracks = [{ id: "downloaded", remoteID: "a".repeat(24) }];
  const playlist = {
    id: "12345678-1234-abcd-9876-abcdef123456",
    name: "Membership",
    trackIDs: [],
    remoteSongIDs: ["a".repeat(24), "b".repeat(24)],
    isSystem: false,
  };
  updatePlaylistRemoteSongIDs(state, playlist);
  assert.deepEqual(playlist.remoteSongIDs, ["b".repeat(24)]);
});
