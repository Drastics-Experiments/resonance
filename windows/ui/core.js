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
  };
}

export function normalizeState(value) {
  const base = createEmptyState();
  const state = value && typeof value === "object" ? { ...base, ...value } : base;
  state.tracks = Array.isArray(state.tracks) ? state.tracks : [];
  state.playlists = Array.isArray(state.playlists) ? state.playlists : [];
  state.favorites = Array.isArray(state.favorites) ? state.favorites : [];
  const seenRemote = new Set();
  state.tracks = state.tracks.filter((track) => !track.remoteID || (seenRemote.has(track.remoteID) ? false : (seenRemote.add(track.remoteID), true)));
  let system = state.playlists.find((playlist) => playlist.isSystem);
  if (!system) {
    system = { id: "liked", name: "Liked Songs", trackIDs: [], isSystem: true };
    state.playlists.unshift(system);
  }
  system.name = "Liked Songs";
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
  return state;
}
