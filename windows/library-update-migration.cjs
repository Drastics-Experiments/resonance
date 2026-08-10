const UNLINKED_DOWNLOAD_MIGRATION_ID = "delete-unlinked-downloads-v1";

function nonemptyText(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function trackHasSourceLink(track) {
  const identities = [track?.sourceIdentity, ...(Array.isArray(track?.sourceIdentities) ? track.sourceIdentities : [])];
  return [track?.sourceURL, track?.downloadSourceURL].some(nonemptyText)
    || identities.some((identity) =>
      nonemptyText(identity?.sourcePageURL) || nonemptyText(identity?.mediaSourceURL));
}

function unlinkedDownloadDecision(track, legacyDownloadOwned) {
  const migrated = {
    ...track,
    preservesUnlinkedImport: typeof track?.preservesUnlinkedImport === "boolean"
      ? track.preservesUnlinkedImport
      : !legacyDownloadOwned,
  };
  const hasRemoteIdentity = [migrated.remoteID, migrated.sourceServer].some(nonemptyText);
  return {
    track: migrated,
    shouldDelete: (hasRemoteIdentity || legacyDownloadOwned)
      && !trackHasSourceLink(migrated)
      && migrated.preservesUnlinkedImport !== true,
  };
}

function pruneTrackReferences(value, retainedTrackIDs, deletedTrackIDs) {
  const state = value && typeof value === "object" ? value : {};
  state.playlists = (Array.isArray(state.playlists) ? state.playlists : []).map((playlist) => ({
    ...playlist,
    trackIDs: (Array.isArray(playlist?.trackIDs) ? playlist.trackIDs : [])
      .filter((id) => retainedTrackIDs.has(id)),
  }));
  state.favorites = (Array.isArray(state.favorites) ? state.favorites : [])
    .filter((id) => retainedTrackIDs.has(id));
  state.currentTrackID = retainedTrackIDs.has(state.currentTrackID) ? state.currentTrackID : null;
  state.playbackQueueIDs = (Array.isArray(state.playbackQueueIDs) ? state.playbackQueueIDs : [])
    .filter((id) => retainedTrackIDs.has(id));
  state.playbackSourceQueueIDs = (Array.isArray(state.playbackSourceQueueIDs) ? state.playbackSourceQueueIDs : [])
    .filter((id) => retainedTrackIDs.has(id));
  state.listeningHistory = (Array.isArray(state.listeningHistory) ? state.listeningHistory : [])
    .filter((entry) => entry?.originatedOnThisDevice === false || !deletedTrackIDs.has(entry?.trackID));
  if (state.profileStates && typeof state.profileStates === "object" && !Array.isArray(state.profileStates)) {
    state.profileStates = Object.fromEntries(Object.entries(state.profileStates).map(([key, snapshot]) => [
      key,
      {
        ...(snapshot || {}),
        playlists: (Array.isArray(snapshot?.playlists) ? snapshot.playlists : []).map((playlist) => ({
          ...playlist,
          trackIDs: (Array.isArray(playlist?.trackIDs) ? playlist.trackIDs : [])
            .filter((id) => retainedTrackIDs.has(id)),
        })),
      },
    ]));
  }
  return state;
}

async function migrateUnlinkedDownloads(value, options) {
  const state = value && typeof value === "object" ? { ...value } : {};
  const migrations = new Set(Array.isArray(state.completedMigrations) ? state.completedMigrations : []);
  if (migrations.has(UNLINKED_DOWNLOAD_MIGRATION_ID)) {
    return { state, changed: false, completed: true, deletedTrackIDs: [] };
  }

  const retained = [];
  const deletedTrackIDs = new Set();
  let completed = true;
  let changed = false;
  for (const track of Array.isArray(state.tracks) ? state.tracks : []) {
    const legacyDownloadOwned = Boolean(options.legacyDownloadOwned(track));
    const decision = unlinkedDownloadDecision(track, legacyDownloadOwned);
    changed ||= decision.track.preservesUnlinkedImport !== track?.preservesUnlinkedImport;
    if (!decision.shouldDelete) {
      retained.push(decision.track);
      continue;
    }
    if (!await options.deleteManagedDownload(decision.track)) {
      retained.push(decision.track);
      completed = false;
      continue;
    }
    if (decision.track.id) deletedTrackIDs.add(decision.track.id);
    changed = true;
  }

  state.tracks = retained;
  const retainedTrackIDs = new Set(retained.map((track) => track?.id).filter(Boolean));
  pruneTrackReferences(state, retainedTrackIDs, deletedTrackIDs);
  if (completed) {
    migrations.add(UNLINKED_DOWNLOAD_MIGRATION_ID);
    changed = true;
  }
  state.completedMigrations = [...migrations];
  return { state, changed, completed, deletedTrackIDs: [...deletedTrackIDs] };
}

module.exports = {
  UNLINKED_DOWNLOAD_MIGRATION_ID,
  migrateUnlinkedDownloads,
  trackHasSourceLink,
  unlinkedDownloadDecision,
};
