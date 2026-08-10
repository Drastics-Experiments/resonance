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

test("selects unlinked downloads while preserving links and flagged imports", () => {
  const unlinked = unlinkedDownloadDecision(track(), true);
  assert.equal(unlinked.shouldDelete, true);
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

test("update migration deletes managed unlinked downloads and prunes local references", async () => {
  const imported = track({
    id: "imported",
    filePath: "C:\\Resonance\\LocalMusic\\imported.m4a",
    preservesUnlinkedImport: true,
  });
  const state = {
    tracks: [track(), imported],
    playlists: [{ id: "mix", trackIDs: ["remote-track", "imported"], remoteSongIDs: ["remote-song"] }],
    favorites: ["remote-track", "imported"],
    currentTrackID: "remote-track",
    playbackQueueIDs: ["remote-track", "imported"],
    playbackSourceQueueIDs: ["remote-track", "imported"],
    listeningHistory: [
      { trackID: "remote-track", originatedOnThisDevice: true },
      { trackID: "remote-history", originatedOnThisDevice: false },
    ],
    profileStates: {
      profile: { playlists: [{ id: "mix", trackIDs: ["remote-track", "imported"] }] },
    },
  };
  const deleted = [];

  const result = await migrateUnlinkedDownloads(state, {
    legacyDownloadOwned: (candidate) => candidate.id === "remote-track",
    deleteManagedDownload: async (candidate) => {
      deleted.push(candidate.filePath);
      return true;
    },
  });

  assert.deepEqual(deleted, ["C:\\Resonance\\ServerCache\\song.m4a"]);
  assert.deepEqual(result.state.tracks.map((candidate) => candidate.id), ["imported"]);
  assert.deepEqual(result.state.playlists[0].trackIDs, ["imported"]);
  assert.deepEqual(result.state.playlists[0].remoteSongIDs, ["remote-song"]);
  assert.deepEqual(result.state.favorites, ["imported"]);
  assert.equal(result.state.currentTrackID, null);
  assert.deepEqual(result.state.playbackQueueIDs, ["imported"]);
  assert.deepEqual(result.state.listeningHistory, [{ trackID: "remote-history", originatedOnThisDevice: false }]);
  assert.deepEqual(result.state.profileStates.profile.playlists[0].trackIDs, ["imported"]);
  assert.deepEqual(result.state.completedMigrations, [UNLINKED_DOWNLOAD_MIGRATION_ID]);
});

test("failed file deletion keeps the track and retries the migration later", async () => {
  const result = await migrateUnlinkedDownloads({ tracks: [track()] }, {
    legacyDownloadOwned: () => true,
    deleteManagedDownload: async () => false,
  });

  assert.equal(result.completed, false);
  assert.equal(result.state.tracks.length, 1);
  assert.deepEqual(result.state.completedMigrations, []);
});
