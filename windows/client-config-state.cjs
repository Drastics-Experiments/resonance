function validRevision(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

function clientConfigRevisionFloor(state, cacheKey) {
  const explicit = state?.revision_floors?.[cacheKey];
  const migrated = state?.entries?.[cacheKey]?.highest_revision;
  return Math.max(validRevision(explicit) ? explicit : 0, validRevision(migrated) ? migrated : 0);
}

function cachedConfigMeetsRevisionFloor(config, state, cacheKey) {
  return Boolean(config?.verified === true
    && validRevision(config.revision)
    && config.revision >= clientConfigRevisionFloor(state, cacheKey));
}

function currentFloorSafeCachedConfig(state, cacheKey, readConfig) {
  if (typeof readConfig !== "function") throw new TypeError("A cache-record verifier is required.");
  const config = readConfig(state?.entries?.[cacheKey]);
  return cachedConfigMeetsRevisionFloor(config, state, cacheKey) ? config : null;
}

async function commitClientConfigRecord({ state, cacheKey, record, revision, persist, maximumEntries = 64 }) {
  if (!state || typeof state !== "object" || typeof cacheKey !== "string" || !record || typeof record !== "object") {
    throw new TypeError("A client-config state, cache key, and record are required.");
  }
  if (!validRevision(revision) || typeof persist !== "function") {
    throw new TypeError("A non-negative revision and persistence callback are required.");
  }
  const previousEntries = state.entries && typeof state.entries === "object" ? state.entries : {};
  const previousFloors = state.revision_floors && typeof state.revision_floors === "object" ? state.revision_floors : {};
  const nextEntries = { ...previousEntries };
  delete nextEntries[cacheKey];
  nextEntries[cacheKey] = record;
  state.entries = Object.fromEntries(Object.entries(nextEntries).slice(-Math.max(1, maximumEntries)));
  state.revision_floors = {
    ...previousFloors,
    [cacheKey]: Math.max(clientConfigRevisionFloor({ entries: previousEntries, revision_floors: previousFloors }, cacheKey), revision),
  };
  try {
    await persist();
  } catch (error) {
    // Never expose an uncommitted cache record. Retain the conservative in-memory
    // high-water so a partial disk write or later request cannot lower the floor.
    state.entries = previousEntries;
    state.revision_floors = {
      ...previousFloors,
      [cacheKey]: Math.max(clientConfigRevisionFloor({ entries: previousEntries, revision_floors: previousFloors }, cacheKey), revision),
    };
    throw error;
  }
  return revision;
}

module.exports = {
  cachedConfigMeetsRevisionFloor,
  clientConfigRevisionFloor,
  commitClientConfigRecord,
  currentFloorSafeCachedConfig,
};
