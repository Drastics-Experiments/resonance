import assert from "node:assert/strict";
import test from "node:test";
import migration from "../library-update-migration.cjs";

const {
  UNLINKED_DOWNLOAD_MIGRATION_ID,
  migrateUnlinkedDownloads,
  unlinkedDownloadDecision,
} = migration;

function track(overrides = {}) {
  return {
    id: "remote-track",
    filePath: "C:\\Resonance\\ServerCache\\song.m4a",
    remoteID: "remote-song",
    sourceServer: "https://music.example",
    ...overrides,
  };
}

test("classifies every legacy download as preserved during upgrade", () => {
  const unlinked = unlinkedDownloadDecision(track(), true);
  assert.equal(unlinked.shouldDelete, false);
  assert.equal(unlinked.track.preservesUnlinkedImport, false);

  assert.equal(unlinkedDownloadDecision(track({ sourceURL: "https://source.example/song" }), true).shouldDelete, false);
  assert.equal(unlinkedDownloadDecision(track({
    sourceIdentity: { mediaSourceURL: "https://media.example/song.m4a" },
  }), true).shouldDelete, false);
  assert.equal(unlinkedDownloadDecision(track({ preservesUnlinkedImport: true }), true).shouldDelete, false);

  const legacyImport = unlinkedDownloadDecision(track(), false);
  assert.equal(legacyImport.shouldDelete, false);
  assert.equal(legacyImport.track.preservesUnlinkedImport, true);
});

test("v1.1.5 server downloads survive upgrade with every library reference intact", async () => {
  const serverDownload = {
    id: "7f96dcad-284d-4f17-9974-22ee172d2274",
    title: "Glass Houses",
    artist: "The Example Band",
    album: "Server Library",
    duration: 241.38,
    artwork: null,
    size: 8_421_337,
    filePath: "C:\\Users\\Example\\AppData\\Roaming\\Resonance\\ServerCache\\Glass Houses.m4a",
    available: true,
    missing: false,
    storageLocation: "server-cache",
    remoteID: "song-42",
    sourceServer: "https://resonance-core.blithe-haven-9710.chatgpt.site",
    syncProfileID: "default",
    remoteModified: "2026-08-06T02:14:10.000Z",
    sourceURL: null,
    sourceIdentity: null,
    sourceIdentities: [],
    sourceSha256: null,
    contentSha256: "6f51078054e9b51732b6a6f490587c858e38ddf8c52bbad6f83288f9f4e7816a",
    dateAdded: "2026-08-06T02:15:00.000Z",
  };
  const state = {
    tracks: [serverDownload],
    playlists: [{ id: "road-trip", name: "Road Trip", trackIDs: [serverDownload.id], remoteSongIDs: [serverDownload.remoteID] }],
    favorites: [serverDownload.id],
    currentTrackID: serverDownload.id,
    playbackQueueIDs: [serverDownload.id],
    playbackSourceQueueIDs: [serverDownload.id],
    listeningHistory: [
      { id: "listen-1", trackID: serverDownload.id, originatedOnThisDevice: true, listenedSeconds: 120 },
    ],
    remoteLikedSongIDs: [serverDownload.remoteID],
    profileStates: {
      default: { playlists: [{ id: "road-trip", trackIDs: [serverDownload.id] }] },
    },
  };

  const result = await migrateUnlinkedDownloads(state, {
    legacyDownloadOwned: (candidate) => candidate.filePath.includes("\\ServerCache\\"),
    deleteManagedDownload: () => { throw new Error("upgrade attempted to delete media"); },
  });

  assert.equal(result.completed, true);
  assert.deepEqual(result.deletedTrackIDs, []);
  assert.equal(result.state.tracks.length, 1);
  assert.equal(result.state.tracks[0].filePath, serverDownload.filePath);
  assert.equal(result.state.tracks[0].preservesUnlinkedImport, false);
  assert.deepEqual(result.state.playlists, state.playlists);
  assert.deepEqual(result.state.favorites, state.favorites);
  assert.equal(result.state.currentTrackID, state.currentTrackID);
  assert.deepEqual(result.state.playbackQueueIDs, state.playbackQueueIDs);
  assert.deepEqual(result.state.playbackSourceQueueIDs, state.playbackSourceQueueIDs);
  assert.deepEqual(result.state.listeningHistory, state.listeningHistory);
  assert.deepEqual(result.state.remoteLikedSongIDs, state.remoteLikedSongIDs);
  assert.deepEqual(result.state.profileStates, state.profileStates);
  assert.deepEqual(result.state.completedMigrations, [UNLINKED_DOWNLOAD_MIGRATION_ID]);
});

test("partially migrated server downloads with an explicit false flag are never retried destructively", async () => {
  const legacy = track({ preservesUnlinkedImport: false });
  const result = await migrateUnlinkedDownloads({ tracks: [legacy] }, {
    legacyDownloadOwned: () => true,
    deleteManagedDownload: () => { throw new Error("upgrade attempted to delete media"); },
  });

  assert.deepEqual(result.deletedTrackIDs, []);
  assert.deepEqual(result.state.tracks, [legacy]);
  assert.deepEqual(result.state.completedMigrations, [UNLINKED_DOWNLOAD_MIGRATION_ID]);
});

test("completed compatibility migration is a no-op", async () => {
  const state = {
    tracks: [track({ preservesUnlinkedImport: false })],
    completedMigrations: [UNLINKED_DOWNLOAD_MIGRATION_ID],
  };
  const result = await migrateUnlinkedDownloads(state);

  assert.equal(result.changed, false);
  assert.equal(result.completed, true);
  assert.equal(result.state.tracks.length, 1);
  assert.equal(result.state.tracks[0].preservesUnlinkedImport, false);
  assert.deepEqual(result.state.completedMigrations, [UNLINKED_DOWNLOAD_MIGRATION_ID]);
});
