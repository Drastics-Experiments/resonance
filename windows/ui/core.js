export function createEmptyState() {
  return {
    tracks: [],
    playlists: [{ id: "liked", name: "Liked Songs", trackIDs: [], isSystem: true }],
    favorites: [],
    serverURL: "https://music.unblocked.mov",
    volume: 0.78,
    playbackRate: 1,
    shuffle: false,
    repeat: false,
    currentTrackID: null,
    position: 0,
    playlistRevision: 0,
    knownRemotePlaylistIDs: [],
    dirtyPlaylistIDs: [],
    deletedPlaylistIDs: [],
    playlistSyncServerURL: null,
  };
}

function unique(values) {
  return [...new Set(values)];
}

function normalizedPlaylistID(value) {
  return String(value || "").toLocaleLowerCase();
}

export function normalizeState(value) {
  const base = createEmptyState();
  const state = value && typeof value === "object" ? { ...base, ...value } : base;
  state.tracks = Array.isArray(state.tracks) ? state.tracks : [];
  state.playlists = Array.isArray(state.playlists) ? state.playlists : [];
  state.favorites = Array.isArray(state.favorites) ? state.favorites : [];
  state.playlistRevision = Number.isInteger(state.playlistRevision) && state.playlistRevision >= 0 ? state.playlistRevision : 0;
  state.knownRemotePlaylistIDs = unique(Array.isArray(state.knownRemotePlaylistIDs) ? state.knownRemotePlaylistIDs.map(normalizedPlaylistID) : []);
  state.dirtyPlaylistIDs = unique(Array.isArray(state.dirtyPlaylistIDs) ? state.dirtyPlaylistIDs.map(normalizedPlaylistID) : []);
  state.deletedPlaylistIDs = unique(Array.isArray(state.deletedPlaylistIDs) ? state.deletedPlaylistIDs.map(normalizedPlaylistID) : []);
  state.playlistSyncServerURL = typeof state.playlistSyncServerURL === "string" ? state.playlistSyncServerURL : null;
  const seenRemote = new Set();
  state.tracks = state.tracks.filter((track) => !track.remoteID || (seenRemote.has(track.remoteID) ? false : (seenRemote.add(track.remoteID), true)));
  let system = state.playlists.find((playlist) => playlist.isSystem);
  if (!system) {
    system = { id: "liked", name: "Liked Songs", trackIDs: [], isSystem: true };
    state.playlists.unshift(system);
  }
  system.name = "Liked Songs";
  system.remoteSongIDs = [];
  state.playlists.filter((playlist) => !playlist.isSystem).forEach((playlist) => {
    playlist.id = normalizedPlaylistID(playlist.id);
    playlist.trackIDs = unique(Array.isArray(playlist.trackIDs) ? playlist.trackIDs : []);
    playlist.remoteSongIDs = unique(Array.isArray(playlist.remoteSongIDs) ? playlist.remoteSongIDs : []);
  });
  const favorites = new Set(state.favorites);
  system.trackIDs = state.tracks.map((track) => track.id).filter((id) => favorites.has(id));
  return state;
}

export function formatTime(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
  const value = Math.floor(seconds);
  return `${Math.floor(value / 60)}:${String(value % 60).padStart(2, "0")}`;
}

export function filterTracks(tracks, query, mode = "all") {
  const value = String(query || "").trim().toLocaleLowerCase();
  let filtered = value
    ? tracks.filter((track) => [track.title, track.artist, track.album].some((field) => String(field || "").toLocaleLowerCase().includes(value)))
    : [...tracks];
  if (mode === "audio") {
    filtered = filtered.filter((track) => /\.(aac|aif|aiff|alac|flac|m4a|m4b|mp3|ogg|opus|wav)$/i.test(String(track.filePath || "")));
  } else if (mode === "recent") {
    filtered.sort((left, right) => Date.parse(right.dateAdded || 0) - Date.parse(left.dateAdded || 0));
  }
  return filtered;
}

export function nextIndex(tracks, currentID, direction = 1, shuffle = false, random = Math.random) {
  if (!tracks.length) return -1;
  if (shuffle && tracks.length > 1) {
    const candidates = tracks.map((_, index) => index).filter((index) => tracks[index].id !== currentID);
    return candidates[Math.floor(random() * candidates.length)];
  }
  const current = Math.max(0, tracks.findIndex((track) => track.id === currentID));
  return (current + direction + tracks.length) % tracks.length;
}

export function tracksForPlaylist(state, playlistID) {
  const playlist = state.playlists.find((item) => item.id === playlistID);
  if (!playlist) return [];
  return playlist.trackIDs.map((id) => state.tracks.find((track) => track.id === id)).filter(Boolean);
}

export function mergeSyncedTracks(state, result) {
  const replaced = new Set(Array.isArray(result?.replacedTrackIDs) ? result.replacedTrackIDs : []);
  if (replaced.size) {
    state.tracks = state.tracks.filter((track) => !replaced.has(track.id));
  }
  state.tracks.push(...(Array.isArray(result?.downloaded) ? result.downloaded : []));
  hydrateRemotePlaylistTracks(state);
  return state;
}

export function updatePlaylistRemoteSongIDs(state, playlist) {
  const unresolved = (playlist.remoteSongIDs || []).filter((remoteID) =>
    !state.tracks.some((track) => track.remoteID === remoteID));
  const downloaded = playlist.trackIDs
    .map((trackID) => state.tracks.find((track) => track.id === trackID)?.remoteID)
    .filter(Boolean);
  playlist.remoteSongIDs = unique([...downloaded, ...unresolved]);
  return playlist;
}

export function hydrateRemotePlaylistTracks(state) {
  for (const playlist of state.playlists.filter((item) => !item.isSystem && Array.isArray(item.remoteSongIDs))) {
    const localOnly = playlist.trackIDs.filter((trackID) => {
      const track = state.tracks.find((item) => item.id === trackID);
      return track && !track.remoteID;
    });
    const downloaded = playlist.remoteSongIDs
      .map((remoteID) => state.tracks.find((track) => track.remoteID === remoteID)?.id)
      .filter(Boolean);
    playlist.trackIDs = unique([...downloaded, ...localOnly]);
  }
  return state;
}

export function remotePlaylistFromLocal(state, playlist) {
  updatePlaylistRemoteSongIDs(state, playlist);
  return {
    id: normalizedPlaylistID(playlist.id),
    name: playlist.name,
    song_ids: [...playlist.remoteSongIDs],
  };
}

export function mergePlaylistDocument(state, remoteDocument) {
  const revision = Number.isInteger(remoteDocument?.revision) && remoteDocument.revision >= 0 ? remoteDocument.revision : 0;
  const remotePlaylists = Array.isArray(remoteDocument?.playlists) ? remoteDocument.playlists : [];
  const deleted = new Set(state.deletedPlaylistIDs.map(normalizedPlaylistID));
  const known = new Set(state.knownRemotePlaylistIDs.map(normalizedPlaylistID));
  const dirty = new Set(state.dirtyPlaylistIDs.map(normalizedPlaylistID));
  const remoteIDs = new Set(remotePlaylists.map((playlist) => normalizedPlaylistID(playlist.id)));
  const merged = remotePlaylists
    .filter((playlist) => !deleted.has(normalizedPlaylistID(playlist.id)))
    .map((playlist) => ({ ...playlist, id: normalizedPlaylistID(playlist.id), song_ids: [...(playlist.song_ids || [])] }));
  let needsUpload = deleted.size > 0;

  for (const playlist of state.playlists.filter((item) => !item.isSystem)) {
    const id = normalizedPlaylistID(playlist.id);
    const isUnsyncedLocalPlaylist = !remoteIDs.has(id) && !known.has(id);
    if (!dirty.has(id) && !isUnsyncedLocalPlaylist) continue;
    const payload = remotePlaylistFromLocal(state, playlist);
    const index = merged.findIndex((item) => normalizedPlaylistID(item.id) === id);
    if (index >= 0) merged[index] = payload;
    else merged.push(payload);
    needsUpload = true;
  }

  return { document: { revision, playlists: merged }, needsUpload };
}

export function applyRemotePlaylistDocument(state, document) {
  const existing = new Map(state.playlists.filter((playlist) => !playlist.isSystem)
    .map((playlist) => [normalizedPlaylistID(playlist.id), playlist]));
  const system = state.playlists.find((playlist) => playlist.isSystem)
    || { id: "liked", name: "Liked Songs", trackIDs: [], remoteSongIDs: [], isSystem: true };
  const remotePlaylists = Array.isArray(document?.playlists) ? document.playlists : [];
  const custom = remotePlaylists.map((remote) => {
    const id = normalizedPlaylistID(remote.id);
    const previous = existing.get(id);
    const localOnly = (previous?.trackIDs || []).filter((trackID) => {
      const track = state.tracks.find((item) => item.id === trackID);
      return track && !track.remoteID;
    });
    const remoteSongIDs = unique(Array.isArray(remote.song_ids) ? remote.song_ids : []);
    const downloaded = remoteSongIDs
      .map((remoteID) => state.tracks.find((track) => track.remoteID === remoteID)?.id)
      .filter(Boolean);
    return {
      id,
      name: remote.name,
      trackIDs: unique([...downloaded, ...localOnly]),
      remoteSongIDs,
      isSystem: false,
    };
  });
  state.playlists = [system, ...custom];
  state.playlistRevision = Number.isInteger(document?.revision) ? document.revision : 0;
  state.knownRemotePlaylistIDs = custom.map((playlist) => playlist.id);
  state.dirtyPlaylistIDs = state.dirtyPlaylistIDs.filter((id) => !state.knownRemotePlaylistIDs.includes(normalizedPlaylistID(id)));
  return normalizeState(state);
}
