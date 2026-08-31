const UNLINKED_DOWNLOAD_MIGRATION_ID = "delete-unlinked-downloads-v1";

function unlinkedDownloadDecision(track, legacyDownloadOwned) {
  const migrated = {
    ...track,
    preservesUnlinkedImport: typeof track?.preservesUnlinkedImport === "boolean"
      ? track.preservesUnlinkedImport
      : !legacyDownloadOwned,
  };
  return {
    track: migrated,
    // Older releases did not persist enough provenance to distinguish a
    // disposable cache entry from the user's only offline copy. Upgrades must
    // therefore preserve every existing track and file.
    shouldDelete: false,
  };
}

async function migrateUnlinkedDownloads(value, options = {}) {
  const state = value && typeof value === "object" ? { ...value } : {};
  const migrations = new Set(Array.isArray(state.completedMigrations) ? state.completedMigrations : []);
  if (migrations.has(UNLINKED_DOWNLOAD_MIGRATION_ID)) {
    return { state, changed: false, completed: true, deletedTrackIDs: [] };
  }

  state.tracks = (Array.isArray(state.tracks) ? state.tracks : [])
    .map((track) => unlinkedDownloadDecision(
      track,
      Boolean(options.legacyDownloadOwned?.(track)),
    ).track);
  migrations.add(UNLINKED_DOWNLOAD_MIGRATION_ID);
  state.completedMigrations = [...migrations];
  return { state, changed: true, completed: true, deletedTrackIDs: [] };
}

module.exports = {
  UNLINKED_DOWNLOAD_MIGRATION_ID,
  migrateUnlinkedDownloads,
  unlinkedDownloadDecision,
};
