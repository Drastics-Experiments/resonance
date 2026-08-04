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
    playbackQueueIDs: [],
    playbackPlaylistID: null,
    playlistRevision: 0,
    knownRemotePlaylistIDs: [],
    dirtyPlaylistIDs: [],
    deletedPlaylistIDs: [],
    playlistSyncServerURL: null,
    syncProfileID: "default",
    syncProfiles: [{ id: "default", name: "Default", is_default: true }],
    profileStates: {},
    remoteLikedSongIDs: [],
    dirtyRemoteLikeSongIDs: [],
    likesDirty: false,
    clipRanges: {},
    dirtyClipRangeKeys: [],
    deletedClipRangeKeys: [],
    listeningHistory: [],
  };
}

function unique(values) {
  return [...new Set(values)];
}

function normalizedPlaylistID(value) {
  return String(value || "").toLocaleLowerCase();
}

function normalizedServerOrigin(value) {
  try {
    return new URL(String(value || "").trim()).origin;
  } catch {
    return "";
  }
}

function normalizedClipRanges(value = {}) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return Object.fromEntries(Object.entries(value).flatMap(([key, range]) => {
    const startSeconds = Number(range?.startSeconds);
    const endSeconds = Number(range?.endSeconds);
    if (!key || !Number.isFinite(startSeconds) || !Number.isFinite(endSeconds) || startSeconds < 0 || endSeconds - startSeconds < 0.25) return [];
    return [[key, { startSeconds, endSeconds }]];
  }));
}

export function clipRangeKey(track) {
  if (!track?.id) return null;
  return track.remoteID ? `remote:${track.remoteID}` : `local:${track.id}`;
}

export function normalizeClipRange(startSeconds, endSeconds, duration = Infinity) {
  const maximum = Number.isFinite(Number(duration)) && Number(duration) > 0 ? Number(duration) : Infinity;
  const start = Math.max(0, Math.min(Number(startSeconds), maximum));
  const end = Math.max(0, Math.min(Number(endSeconds), maximum));
  if (!Number.isFinite(start) || !Number.isFinite(end) || end - start < 0.25) return null;
  return { startSeconds: start, endSeconds: end };
}

export function playbackRangeForTrack(state, track) {
  const key = clipRangeKey(track);
  if (!key) return null;
  const stored = state?.clipRanges?.[key];
  return stored ? normalizeClipRange(stored.startSeconds, stored.endSeconds, track.duration) : null;
}

export function setClipRangeForTrack(state, track, startSeconds, endSeconds) {
  const key = clipRangeKey(track);
  const range = key ? normalizeClipRange(startSeconds, endSeconds, track?.duration) : null;
  if (!key || !range) return null;
  state.clipRanges = normalizedClipRanges(state.clipRanges);
  state.clipRanges[key] = range;
  if (track.remoteID) {
    state.dirtyClipRangeKeys = unique([...(state.dirtyClipRangeKeys || []), key]);
    state.deletedClipRangeKeys = (state.deletedClipRangeKeys || []).filter((candidate) => candidate !== key);
  }
  return range;
}

export function removeClipRangeForTrack(state, track) {
  const key = clipRangeKey(track);
  if (!key) return false;
  state.clipRanges = normalizedClipRanges(state.clipRanges);
  const existed = Boolean(state.clipRanges[key]);
  delete state.clipRanges[key];
  if (track.remoteID) {
    state.dirtyClipRangeKeys = unique([...(state.dirtyClipRangeKeys || []), key]);
    state.deletedClipRangeKeys = unique([...(state.deletedClipRangeKeys || []), key]);
  }
  return existed;
}

export function profileStateKey(serverURL, profileID = "default") {
  return `${normalizedServerOrigin(serverURL) || String(serverURL || "").trim()}#profile=${profileID || "default"}`;
}

function customPlaylistSnapshot(playlists) {
  return (Array.isArray(playlists) ? playlists : [])
    .filter((playlist) => playlist && !playlist.isSystem)
    .map((playlist) => ({
      ...playlist,
      id: normalizedPlaylistID(playlist.id),
      trackIDs: unique(Array.isArray(playlist.trackIDs) ? playlist.trackIDs : []),
      remoteSongIDs: unique(Array.isArray(playlist.remoteSongIDs) ? playlist.remoteSongIDs : []),
      isSystem: false,
    }));
}

function normalizedProfileState(value = {}) {
  return {
    playlists: customPlaylistSnapshot(value.playlists),
    playlistRevision: Number.isInteger(value.playlistRevision) && value.playlistRevision >= 0 ? value.playlistRevision : 0,
    knownRemotePlaylistIDs: unique(Array.isArray(value.knownRemotePlaylistIDs) ? value.knownRemotePlaylistIDs.map(normalizedPlaylistID) : []),
    dirtyPlaylistIDs: unique(Array.isArray(value.dirtyPlaylistIDs) ? value.dirtyPlaylistIDs.map(normalizedPlaylistID) : []),
    deletedPlaylistIDs: unique(Array.isArray(value.deletedPlaylistIDs) ? value.deletedPlaylistIDs.map(normalizedPlaylistID) : []),
    playlistSyncServerURL: typeof value.playlistSyncServerURL === "string" ? value.playlistSyncServerURL : null,
    remoteLikedSongIDs: unique(Array.isArray(value.remoteLikedSongIDs) ? value.remoteLikedSongIDs.filter((id) => typeof id === "string" && id) : []),
    dirtyRemoteLikeSongIDs: unique(Array.isArray(value.dirtyRemoteLikeSongIDs) ? value.dirtyRemoteLikeSongIDs.filter((id) => typeof id === "string" && id) : []),
    likesDirty: Boolean(value.likesDirty),
    clipRanges: normalizedClipRanges(value.clipRanges),
    dirtyClipRangeKeys: unique(Array.isArray(value.dirtyClipRangeKeys) ? value.dirtyClipRangeKeys.filter((key) => typeof key === "string" && key.startsWith("remote:")) : []),
    deletedClipRangeKeys: unique(Array.isArray(value.deletedClipRangeKeys) ? value.deletedClipRangeKeys.filter((key) => typeof key === "string" && key.startsWith("remote:")) : []),
  };
}

export function storeActiveProfileState(state) {
  state.profileStates = state.profileStates && typeof state.profileStates === "object" ? state.profileStates : {};
  const key = profileStateKey(state.serverURL, state.syncProfileID);
  state.profileStates[key] = normalizedProfileState({
    playlists: state.playlists,
    playlistRevision: state.playlistRevision,
    knownRemotePlaylistIDs: state.knownRemotePlaylistIDs,
    dirtyPlaylistIDs: state.dirtyPlaylistIDs,
    deletedPlaylistIDs: state.deletedPlaylistIDs,
    playlistSyncServerURL: state.playlistSyncServerURL,
    remoteLikedSongIDs: state.remoteLikedSongIDs,
    dirtyRemoteLikeSongIDs: state.dirtyRemoteLikeSongIDs,
    likesDirty: state.likesDirty,
    clipRanges: state.clipRanges,
    dirtyClipRangeKeys: state.dirtyClipRangeKeys,
    deletedClipRangeKeys: state.deletedClipRangeKeys,
  });
  return state;
}

export function restoreProfileState(state, profileID, serverURL = state.serverURL) {
  state.profileStates = state.profileStates && typeof state.profileStates === "object" ? state.profileStates : {};
  const snapshot = normalizedProfileState(state.profileStates[profileStateKey(serverURL, profileID)]);
  const system = state.playlists.find((playlist) => playlist.isSystem)
    || { id: "liked", name: "Liked Songs", trackIDs: [], remoteSongIDs: [], isSystem: true };
  state.syncProfileID = profileID || "default";
  state.serverURL = serverURL;
  state.playlists = [system, ...snapshot.playlists];
  state.playlistRevision = snapshot.playlistRevision;
  state.knownRemotePlaylistIDs = snapshot.knownRemotePlaylistIDs;
  state.dirtyPlaylistIDs = snapshot.dirtyPlaylistIDs;
  state.deletedPlaylistIDs = snapshot.deletedPlaylistIDs;
  state.playlistSyncServerURL = snapshot.playlistSyncServerURL;
  state.remoteLikedSongIDs = snapshot.remoteLikedSongIDs;
  state.dirtyRemoteLikeSongIDs = snapshot.dirtyRemoteLikeSongIDs;
  state.likesDirty = snapshot.likesDirty;
  state.clipRanges = snapshot.clipRanges;
  state.dirtyClipRangeKeys = snapshot.dirtyClipRangeKeys;
  state.deletedClipRangeKeys = snapshot.deletedClipRangeKeys;
  hydrateRemotePlaylistTracks(state);
  hydrateRemoteLikedTracks(state);
  return state;
}

export function trackBelongsToActiveProfile(state, track) {
  if (!track?.remoteID) return true;
  const profileMatches = (track.syncProfileID || "default") === (state.syncProfileID || "default");
  const source = normalizedServerOrigin(track.sourceServer);
  const activeServer = normalizedServerOrigin(state.serverURL);
  return profileMatches && (!source || source === activeServer);
}

export function tracksForActiveProfile(state) {
  return (Array.isArray(state?.tracks) ? state.tracks : []).filter((track) => trackBelongsToActiveProfile(state, track));
}

export function resolveSyncProfile(profiles, query, defaultProfileID = "default") {
  const availableProfiles = Array.isArray(profiles) ? profiles : [];
  const normalizedQuery = String(query || "").trim().toLocaleLowerCase();
  const requestedProfile = availableProfiles.find((profile) =>
    String(profile?.id || "").toLocaleLowerCase() === normalizedQuery
    || String(profile?.name || "").toLocaleLowerCase() === normalizedQuery);
  if (requestedProfile) return { profile: requestedProfile, fellBackToDefault: false };

  const declaredDefaultID = String(defaultProfileID || "default");
  const defaultProfile = availableProfiles.find((profile) => profile?.id === declaredDefaultID)
    || availableProfiles.find((profile) => profile?.is_default)
    || availableProfiles.find((profile) => profile?.id === "default")
    || null;
  return { profile: defaultProfile, fellBackToDefault: Boolean(defaultProfile) };
}

export function normalizeState(value) {
  const base = createEmptyState();
  const hadRemoteLikedSongIDs = Array.isArray(value?.remoteLikedSongIDs);
  const hadDirtyRemoteLikeSongIDs = Array.isArray(value?.dirtyRemoteLikeSongIDs);
  const state = value && typeof value === "object" ? { ...base, ...value } : base;
  state.tracks = Array.isArray(state.tracks) ? state.tracks : [];
  state.playlists = Array.isArray(state.playlists) ? state.playlists : [];
  state.favorites = Array.isArray(state.favorites) ? state.favorites : [];
  state.playlistRevision = Number.isInteger(state.playlistRevision) && state.playlistRevision >= 0 ? state.playlistRevision : 0;
  state.knownRemotePlaylistIDs = unique(Array.isArray(state.knownRemotePlaylistIDs) ? state.knownRemotePlaylistIDs.map(normalizedPlaylistID) : []);
  state.dirtyPlaylistIDs = unique(Array.isArray(state.dirtyPlaylistIDs) ? state.dirtyPlaylistIDs.map(normalizedPlaylistID) : []);
  state.deletedPlaylistIDs = unique(Array.isArray(state.deletedPlaylistIDs) ? state.deletedPlaylistIDs.map(normalizedPlaylistID) : []);
  state.playlistSyncServerURL = typeof state.playlistSyncServerURL === "string" ? state.playlistSyncServerURL : null;
  state.syncProfileID = typeof state.syncProfileID === "string" && state.syncProfileID ? state.syncProfileID : "default";
  state.syncProfiles = Array.isArray(state.syncProfiles) && state.syncProfiles.length
    ? state.syncProfiles
    : [{ id: "default", name: "Default", is_default: true }];
  state.profileStates = state.profileStates && typeof state.profileStates === "object"
    ? Object.fromEntries(Object.entries(state.profileStates).map(([key, snapshot]) => [key, normalizedProfileState(snapshot)]))
    : {};
  state.remoteLikedSongIDs = unique(Array.isArray(state.remoteLikedSongIDs) ? state.remoteLikedSongIDs.filter((id) => typeof id === "string" && id) : []);
  state.dirtyRemoteLikeSongIDs = unique(Array.isArray(state.dirtyRemoteLikeSongIDs) ? state.dirtyRemoteLikeSongIDs.filter((id) => typeof id === "string" && id) : []);
  state.likesDirty = Boolean(state.likesDirty);
  state.clipRanges = normalizedClipRanges(state.clipRanges);
  state.dirtyClipRangeKeys = unique(Array.isArray(state.dirtyClipRangeKeys) ? state.dirtyClipRangeKeys.filter((key) => typeof key === "string" && key.startsWith("remote:")) : []);
  state.deletedClipRangeKeys = unique(Array.isArray(state.deletedClipRangeKeys) ? state.deletedClipRangeKeys.filter((key) => typeof key === "string" && key.startsWith("remote:")) : []);
  state.listeningHistory = (Array.isArray(state.listeningHistory) ? state.listeningHistory : [])
    .filter((entry) =>
      entry
      && typeof entry.id === "string"
      && typeof entry.trackID === "string"
      && Number.isFinite(Date.parse(entry.startedAt)))
    .map((entry) => ({
      id: entry.id,
      trackID: entry.trackID,
      profileID: typeof entry.profileID === "string" && entry.profileID ? entry.profileID : "default",
      startedAt: new Date(entry.startedAt).toISOString(),
      listenedSeconds: Math.max(0, Number(entry.listenedSeconds) || 0),
    }))
    .slice(-2000);
  const activeServerOrigin = normalizedServerOrigin(state.serverURL);
  state.tracks = state.tracks.map((track) => track?.remoteID ? {
    ...track,
    sourceServer: normalizedServerOrigin(track.sourceServer) || activeServerOrigin,
    syncProfileID: track.syncProfileID || "default",
  } : track);
  reconcileServerBackedTrackDuplicates(state);
  const seenRemote = new Set();
  state.tracks = state.tracks.filter((track) => {
    if (!track?.remoteID) return true;
    const key = `${track.sourceServer}#${track.syncProfileID}#${track.remoteID}`;
    if (seenRemote.has(key)) return false;
    seenRemote.add(key);
    return true;
  });
  const trackIDs = new Set(state.tracks.map((track) => track.id));
  state.playbackQueueIDs = unique(Array.isArray(state.playbackQueueIDs) ? state.playbackQueueIDs : [])
    .filter((id) => trackIDs.has(id));
  state.playbackPlaylistID = typeof state.playbackPlaylistID === "string" ? state.playbackPlaylistID : null;
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
  if (!hadRemoteLikedSongIDs) {
    state.remoteLikedSongIDs = unique(state.tracks
      .filter((track) => track.remoteID && favorites.has(track.id) && (track.syncProfileID || "default") === state.syncProfileID)
      .map((track) => track.remoteID));
  }
  if (state.likesDirty && !hadDirtyRemoteLikeSongIDs) {
    state.dirtyRemoteLikeSongIDs = unique(state.tracks
      .filter((track) => track.remoteID && (track.syncProfileID || "default") === state.syncProfileID)
      .map((track) => track.remoteID));
  }
  state.likesDirty = state.dirtyRemoteLikeSongIDs.length > 0;
  system.trackIDs = tracksForActiveProfile(state).map((track) => track.id).filter((id) => favorites.has(id));
  storeActiveProfileState(state);
  return state;
}

function localDayKey(value) {
  const date = new Date(value);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

function hourKey(value) {
  return `hour-${Math.floor(new Date(value).getTime() / (60 * 60 * 1000))}`;
}

function listeningHistoryEntryMatchesActiveProfile(state, entry) {
  const activeProfileID = typeof state?.syncProfileID === "string" && state.syncProfileID
    ? state.syncProfileID
    : "default";
  const entryProfileID = typeof entry?.profileID === "string" && entry.profileID
    ? entry.profileID
    : "default";
  return entryProfileID === activeProfileID;
}

export function summarizeListeningHistory(state, dayCount = 30, now = new Date(), windowOffset = 0) {
  const requestedCount = Math.max(1, Math.min(365, Math.floor(Number(dayCount) || 30)));
  const offset = Math.max(0, Math.floor(Number(windowOffset) || 0));
  const hourly = requestedCount === 1;
  const count = hourly ? 24 : requestedCount;
  const end = new Date(now);
  end.setHours(0, 0, 0, 0);
  end.setDate(end.getDate() - offset * requestedCount);
  const days = Array.from({ length: count }, (_, index) => {
    const date = new Date(end);
    if (hourly) date.setHours(index, 0, 0, 0);
    else date.setDate(end.getDate() - (count - index - 1));
    return { key: hourly ? hourKey(date) : localDayKey(date), date, seconds: 0, plays: 0 };
  });
  const byKey = new Map(days.map((day) => [day.key, day]));
  const dayIndexByKey = new Map(days.map((day, index) => [day.key, index]));
  const trackIDs = new Set();
  const songSeries = new Map();
  const todayKey = localDayKey(now);
  let todaySeconds = 0;
  let todayPlays = 0;
  for (const entry of state?.listeningHistory || []) {
    if (!listeningHistoryEntryMatchesActiveProfile(state, entry)) continue;
    const timestamp = Date.parse(entry.startedAt);
    if (!Number.isFinite(timestamp)) continue;
    const seconds = Math.max(0, Number(entry.listenedSeconds) || 0);
    if (localDayKey(timestamp) === todayKey) {
      todaySeconds += seconds;
      todayPlays += 1;
    }
    const key = hourly ? hourKey(timestamp) : localDayKey(timestamp);
    const day = byKey.get(key);
    if (!day) continue;
    day.seconds += seconds;
    day.plays += 1;
    if (entry.trackID) {
      trackIDs.add(entry.trackID);
      if (!songSeries.has(entry.trackID)) {
        songSeries.set(entry.trackID, {
          trackID: entry.trackID,
          seconds: 0,
          plays: 0,
          days: days.map((item) => ({ key: item.key, date: item.date, seconds: 0, plays: 0 })),
        });
      }
      const series = songSeries.get(entry.trackID);
      const seriesDay = series.days[dayIndexByKey.get(key)];
      series.seconds += seconds;
      series.plays += 1;
      seriesDay.seconds += seconds;
      seriesDay.plays += 1;
    }
  }
  return {
    granularity: hourly ? "hour" : "day",
    days,
    totalSeconds: days.reduce((total, day) => total + day.seconds, 0),
    plays: days.reduce((total, day) => total + day.plays, 0),
    todaySeconds,
    todayPlays,
    songs: trackIDs.size,
    songSeries: [...songSeries.values()].sort((left, right) => right.seconds - left.seconds || right.plays - left.plays),
  };
}

export function summarizeListeningStats(state, now = new Date()) {
  const tracks = new Map((state?.tracks || []).map((track) => [track.id, track]));
  const songs = new Map();
  const artists = new Map();
  const todayKey = localDayKey(now);
  let totalSeconds = 0;
  let plays = 0;
  let todaySeconds = 0;

  for (const entry of state?.listeningHistory || []) {
    if (!listeningHistoryEntryMatchesActiveProfile(state, entry)) continue;
    const timestamp = Date.parse(entry.startedAt);
    if (!Number.isFinite(timestamp)) continue;
    const seconds = Math.max(0, Number(entry.listenedSeconds) || 0);
    totalSeconds += seconds;
    plays += 1;
    if (localDayKey(timestamp) === todayKey) todaySeconds += seconds;
    if (!entry.trackID) continue;

    const song = songs.get(entry.trackID) || { trackID: entry.trackID, seconds: 0, plays: 0 };
    song.seconds += seconds;
    song.plays += 1;
    songs.set(entry.trackID, song);

    const artist = tracks.get(entry.trackID)?.artist?.trim() || "Unknown artist";
    const artistStats = artists.get(artist) || { artist, seconds: 0, plays: 0 };
    artistStats.seconds += seconds;
    artistStats.plays += 1;
    artists.set(artist, artistStats);
  }

  const rankedSongs = [...songs.values()].sort((left, right) => right.seconds - left.seconds || right.plays - left.plays);
  const rankedArtists = [...artists.values()].sort((left, right) => right.seconds - left.seconds || right.plays - left.plays);
  return {
    totalSeconds,
    plays,
    songs: songs.size,
    averageSeconds: plays ? totalSeconds / plays : 0,
    todaySeconds,
    topTrackID: rankedSongs[0]?.trackID || null,
    topArtist: rankedArtists[0]?.artist || "—",
    songRanking: rankedSongs,
  };
}

export function formatHistoryWindowLabel(summary, now = new Date(), locale = undefined) {
  const start = summary?.days?.at(0)?.date;
  const end = summary?.days?.at(-1)?.date;
  if (!(start instanceof Date) || !(end instanceof Date)) return "";
  const startYear = start.getFullYear();
  const endYear = end.getFullYear();
  const currentYear = new Date(now).getFullYear();
  const sameDay = startYear === endYear
    && start.getMonth() === end.getMonth()
    && start.getDate() === end.getDate();
  const dateLabel = (date, includeYear = false) => new Intl.DateTimeFormat(locale, {
    month: "long",
    day: "numeric",
    ...(includeYear ? { year: "numeric" } : {}),
  }).format(date);
  if (sameDay) return dateLabel(start, startYear !== currentYear);
  if (startYear === endYear && start.getMonth() === end.getMonth()) {
    const month = new Intl.DateTimeFormat(locale, { month: "long" }).format(start);
    return `${month} ${start.getDate()}–${end.getDate()}${endYear === currentYear ? "" : `, ${endYear}`}`;
  }
  if (startYear === endYear) {
    return `${dateLabel(start)}–${dateLabel(end)}${endYear === currentYear ? "" : `, ${endYear}`}`;
  }
  return `${dateLabel(start, true)}–${dateLabel(end, true)}`;
}

export function niceChartMaximum(value) {
  const peak = Math.max(0, Number(value) || 0);
  if (peak <= 0) return 1;
  const roughStep = peak / 4;
  const magnitude = 10 ** Math.floor(Math.log10(roughStep));
  const normalizedStep = roughStep / magnitude;
  const multiplier = normalizedStep <= 1
    ? 1
    : normalizedStep <= 2
      ? 2
      : normalizedStep <= 2.5
        ? 2.5
        : normalizedStep <= 5
          ? 5
          : 10;
  const step = multiplier * magnitude;
  let maximum = Math.ceil(peak / step) * step;
  if (maximum <= peak) maximum += step;
  return Number(maximum.toPrecision(12));
}

export function formatTime(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
  const value = Math.floor(seconds);
  return `${Math.floor(value / 60)}:${String(value % 60).padStart(2, "0")}`;
}

export function normalizedVolume(value, fallback = 0.78) {
  const volume = Number(value);
  return Number.isFinite(volume) ? Math.max(0, Math.min(1, volume)) : fallback;
}

export function filterTracks(tracks, query, mode = "all") {
  const value = String(query || "").trim().toLocaleLowerCase();
  let filtered = value
    ? tracks.filter((track) => [track.title, track.artist, track.album, track.filePath].some((field) => String(field || "").toLocaleLowerCase().includes(value)))
    : [...tracks];
  if (mode === "audio") {
    filtered = filtered.filter((track) => /\.(aac|aif|aiff|alac|flac|m4a|m4b|mp3|ogg|opus|wav)$/i.test(String(track.filePath || "")));
  } else if (mode === "recent") {
    filtered.sort((left, right) => Date.parse(right.dateAdded || 0) - Date.parse(left.dateAdded || 0));
  }
  return filtered;
}

export function filterPlaylists(playlists, tracks, query) {
  const value = String(query || "").trim().toLocaleLowerCase();
  if (!value) return [...playlists];
  return playlists.filter((playlist) => {
    if (String(playlist.name || "").toLocaleLowerCase().includes(value)) return true;
    return (playlist.trackIDs || []).some((trackID) => {
      const track = tracks.find((item) => item.id === trackID);
      return [track?.title, track?.artist, track?.album].some((field) => String(field || "").toLocaleLowerCase().includes(value));
    });
  });
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

function uploadedRemoteSong(value) {
  if (!value || typeof value !== "object") return null;
  return value.duplicate_of || value.duplicateOf || value.song || value;
}

export function reconcileUploadedTrack(state, trackID, remoteSong, options = {}) {
  const target = state.tracks.find((track) => track?.id === trackID);
  const remote = uploadedRemoteSong(remoteSong);
  const remoteID = String(remote?.id || "").trim();
  if (!target || !remoteID) return false;
  const profileID = String(options.profileID || state.syncProfileID || "default");
  const sourceServer = normalizedServerOrigin(options.serverURL || state.serverURL);
  const duplicateIDs = new Set(state.tracks
    .filter((track) =>
      track?.id !== target.id
      && track?.remoteID === remoteID
      && (track.syncProfileID || "default") === profileID
      && (!sourceServer || !normalizedServerOrigin(track.sourceServer) || normalizedServerOrigin(track.sourceServer) === sourceServer))
    .map((track) => track.id));
  const identityChanged = target.remoteID !== remoteID
    || (target.syncProfileID || null) !== profileID
    || normalizedServerOrigin(target.sourceServer) !== sourceServer;
  if (!identityChanged && duplicateIDs.size === 0) return false;

  const duplicate = state.tracks.find((track) => duplicateIDs.has(track.id));
  const localClipKey = `local:${target.id}`;
  const localClipRange = state.clipRanges?.[localClipKey];
  if (!target.artwork && duplicate?.artwork) target.artwork = duplicate.artwork;
  if (!target.filePath && duplicate?.filePath) {
    target.filePath = duplicate.filePath;
    target.fileUrl = duplicate.fileUrl;
  }
  target.remoteID = remoteID;
  target.syncProfileID = profileID;
  target.sourceServer = sourceServer || target.sourceServer || null;
  target.remoteModified = remote.modified_at || remote.modified_utc || target.remoteModified || null;

  const remap = (values) => unique((Array.isArray(values) ? values : [])
    .map((value) => duplicateIDs.has(value) ? target.id : value));
  const wasFavorite = state.favorites.includes(target.id)
    || state.favorites.some((id) => duplicateIDs.has(id));
  state.favorites = remap(state.favorites).filter((id) => !duplicateIDs.has(id));
  if (wasFavorite && !state.favorites.includes(target.id)) state.favorites.push(target.id);

  for (const playlist of state.playlists) {
    const affected = (playlist.trackIDs || []).some((id) => id === target.id || duplicateIDs.has(id));
    playlist.trackIDs = remap(playlist.trackIDs);
    if (!affected || playlist.isSystem) continue;
    updatePlaylistRemoteSongIDs(state, playlist);
    const id = normalizedPlaylistID(playlist.id);
    state.deletedPlaylistIDs = state.deletedPlaylistIDs.filter((value) => normalizedPlaylistID(value) !== id);
    state.dirtyPlaylistIDs = unique([...state.dirtyPlaylistIDs.map(normalizedPlaylistID), id]);
  }

  state.playbackQueueIDs = remap(state.playbackQueueIDs);
  if (duplicateIDs.has(state.currentTrackID)) state.currentTrackID = target.id;
  state.listeningHistory = (state.listeningHistory || []).map((entry) =>
    duplicateIDs.has(entry.trackID) ? { ...entry, trackID: target.id } : entry);
  state.tracks = state.tracks.filter((track) => !duplicateIDs.has(track.id));

  if (wasFavorite) {
    state.remoteLikedSongIDs = unique([...state.remoteLikedSongIDs, remoteID]);
    state.dirtyRemoteLikeSongIDs = unique([...state.dirtyRemoteLikeSongIDs, remoteID]);
    state.likesDirty = true;
  }
  if (localClipRange) {
    const remoteClipKey = `remote:${remoteID}`;
    state.clipRanges[remoteClipKey] = localClipRange;
    delete state.clipRanges[localClipKey];
    state.dirtyClipRangeKeys = unique([...state.dirtyClipRangeKeys, remoteClipKey]);
    state.deletedClipRangeKeys = state.deletedClipRangeKeys.filter((key) => key !== remoteClipKey);
  }
  hydrateRemotePlaylistTracks(state);
  hydrateRemoteLikedTracks(state);
  return true;
}

export function reconcileServerBackedTrackDuplicates(state) {
  const localByContent = new Map();
  for (const track of state.tracks) {
    const hash = String(track?.contentSha256 || "").trim().toLocaleLowerCase();
    const size = Number(track?.size);
    if (!track?.remoteID && hash && Number.isFinite(size) && size > 0) {
      localByContent.set(`${size}#${hash}`, track.id);
    }
  }
  let reconciled = 0;
  for (const serverTrack of [...state.tracks]) {
    const hash = String(serverTrack?.contentSha256 || "").trim().toLocaleLowerCase();
    const size = Number(serverTrack?.size);
    if (!serverTrack?.remoteID || !hash || !Number.isFinite(size) || size <= 0) continue;
    const localTrackID = localByContent.get(`${size}#${hash}`);
    if (!localTrackID) continue;
    if (reconcileUploadedTrack(state, localTrackID, { ...serverTrack, id: serverTrack.remoteID }, {
      serverURL: serverTrack.sourceServer || state.serverURL,
      profileID: serverTrack.syncProfileID || state.syncProfileID,
    })) reconciled += 1;
  }
  return reconciled;
}

export function mergeSyncedTracks(state, result) {
  const replaced = new Set(Array.isArray(result?.replacedTrackIDs) ? result.replacedTrackIDs : []);
  if (replaced.size) {
    state.tracks = state.tracks.filter((track) => !replaced.has(track.id));
  }
  state.tracks.push(...(Array.isArray(result?.downloaded) ? result.downloaded : []));
  reconcileServerBackedTrackDuplicates(state);
  hydrateRemotePlaylistTracks(state);
  hydrateRemoteLikedTracks(state);
  return state;
}

export function formatServerDownloadFailureNotice(failures) {
  const items = (Array.isArray(failures) ? failures : []).map((failure) => {
    const title = String(failure?.title || failure?.filename || failure?.id || "Untitled song");
    const artist = String(failure?.artist || "").trim();
    return `“${title}”${artist ? ` — ${artist}` : ""}`;
  });
  if (!items.length) return "";
  return `${items.length} song${items.length === 1 ? "" : "s"} failed to download after retrying: ${items.join("; ")}.`;
}

export function updatePlaylistRemoteSongIDs(state, playlist) {
  const unresolved = (playlist.remoteSongIDs || []).filter((remoteID) =>
    !state.tracks.some((track) => track.remoteID === remoteID && trackBelongsToActiveProfile(state, track)));
  const downloaded = playlist.trackIDs
    .map((trackID) => state.tracks.find((track) => track.id === trackID && trackBelongsToActiveProfile(state, track))?.remoteID)
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
      .map((remoteID) => state.tracks.find((track) => track.remoteID === remoteID && trackBelongsToActiveProfile(state, track))?.id)
      .filter(Boolean);
    playlist.trackIDs = unique([...downloaded, ...localOnly]);
  }
  return state;
}

export function hydrateRemoteLikedTracks(state) {
  const likedRemoteIDs = new Set(state.remoteLikedSongIDs);
  const localFavorites = state.favorites.filter((trackID) => {
    const track = state.tracks.find((item) => item.id === trackID);
    return track && !track.remoteID;
  });
  const remoteFavorites = state.tracks
    .filter((track) =>
      track.remoteID
      && trackBelongsToActiveProfile(state, track)
      && likedRemoteIDs.has(track.remoteID))
    .map((track) => track.id);
  state.favorites = unique([...localFavorites, ...remoteFavorites]);
  const system = state.playlists.find((playlist) => playlist.isSystem);
  if (system) system.trackIDs = tracksForActiveProfile(state).map((track) => track.id).filter((id) => state.favorites.includes(id));
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

  const likedSongIDs = new Set(Array.isArray(remoteDocument?.liked_song_ids) ? remoteDocument.liked_song_ids : []);
  const intendedLikedSongIDs = new Set(state.remoteLikedSongIDs);
  for (const remoteID of state.dirtyRemoteLikeSongIDs) {
    if (intendedLikedSongIDs.has(remoteID)) likedSongIDs.add(remoteID);
    else likedSongIDs.delete(remoteID);
  }

  const clipRangesBySongID = new Map((Array.isArray(remoteDocument?.clip_ranges) ? remoteDocument.clip_ranges : [])
    .filter((range) => range && typeof range.song_id === "string")
    .map((range) => [range.song_id, {
      song_id: range.song_id,
      start_seconds: Number(range.start_seconds),
      end_seconds: Number(range.end_seconds),
    }]));
  const deletedClipRangeKeys = new Set(state.deletedClipRangeKeys || []);
  for (const key of state.dirtyClipRangeKeys || []) {
    if (!key.startsWith("remote:")) continue;
    const songID = key.slice("remote:".length);
    if (deletedClipRangeKeys.has(key)) {
      clipRangesBySongID.delete(songID);
      continue;
    }
    const range = state.clipRanges?.[key];
    if (!range) continue;
    clipRangesBySongID.set(songID, {
      song_id: songID,
      start_seconds: range.startSeconds,
      end_seconds: range.endSeconds,
    });
  }
  return {
    document: {
      revision,
      playlists: merged,
      liked_song_ids: [...likedSongIDs],
      clip_ranges: [...clipRangesBySongID.values()],
    },
    needsUpload: needsUpload
      || state.dirtyRemoteLikeSongIDs.length > 0
      || state.dirtyClipRangeKeys.length > 0
      || state.deletedClipRangeKeys.length > 0,
  };
}

export function applyRemotePlaylistDocument(state, document, options = {}) {
  const existing = new Map(state.playlists.filter((playlist) => !playlist.isSystem)
    .map((playlist) => [normalizedPlaylistID(playlist.id), playlist]));
  const preservingLocalIDs = new Set((options.preservingLocalIDs || []).map(normalizedPlaylistID));
  const deletedPlaylistIDs = new Set(state.deletedPlaylistIDs.map(normalizedPlaylistID));
  const system = state.playlists.find((playlist) => playlist.isSystem)
    || { id: "liked", name: "Liked Songs", trackIDs: [], remoteSongIDs: [], isSystem: true };
  const remotePlaylists = Array.isArray(document?.playlists) ? document.playlists : [];
  const custom = remotePlaylists.flatMap((remote) => {
    const id = normalizedPlaylistID(remote.id);
    if (deletedPlaylistIDs.has(id)) return [];
    const previous = existing.get(id);
    if (preservingLocalIDs.has(id) && previous) return [{ ...previous, id, isSystem: false }];
    const localOnly = (previous?.trackIDs || []).filter((trackID) => {
      const track = state.tracks.find((item) => item.id === trackID);
      return track && !track.remoteID;
    });
    const remoteSongIDs = unique(Array.isArray(remote.song_ids) ? remote.song_ids : []);
    const downloaded = remoteSongIDs
      .map((remoteID) => state.tracks.find((track) => track.remoteID === remoteID && trackBelongsToActiveProfile(state, track))?.id)
      .filter(Boolean);
    return [{
      id,
      name: remote.name,
      trackIDs: unique([...downloaded, ...localOnly]),
      remoteSongIDs,
      isSystem: false,
    }];
  });
  const remoteIDs = new Set(remotePlaylists.map((playlist) => normalizedPlaylistID(playlist.id)));
  custom.push(...[...existing.values()].filter((playlist) => {
    const id = normalizedPlaylistID(playlist.id);
    return preservingLocalIDs.has(id) && !remoteIDs.has(id) && !deletedPlaylistIDs.has(id);
  }));
  state.playlists = [system, ...custom];
  state.playlistRevision = Number.isInteger(document?.revision) ? document.revision : 0;
  state.knownRemotePlaylistIDs = remotePlaylists
    .map((playlist) => normalizedPlaylistID(playlist.id))
    .filter((id) => !deletedPlaylistIDs.has(id));
  state.dirtyPlaylistIDs = state.dirtyPlaylistIDs.filter((id) =>
    preservingLocalIDs.has(normalizedPlaylistID(id))
    || !state.knownRemotePlaylistIDs.includes(normalizedPlaylistID(id)));
  const remoteLikedSongIDs = new Set(unique(Array.isArray(document?.liked_song_ids) ? document.liked_song_ids : []));
  const intendedLikedSongIDs = new Set(state.remoteLikedSongIDs);
  for (const remoteID of state.dirtyRemoteLikeSongIDs) {
    if (intendedLikedSongIDs.has(remoteID)) remoteLikedSongIDs.add(remoteID);
    else remoteLikedSongIDs.delete(remoteID);
  }
  state.remoteLikedSongIDs = [...remoteLikedSongIDs];
  state.likesDirty = state.dirtyRemoteLikeSongIDs.length > 0;
  if (Array.isArray(document?.clip_ranges)) {
    const preservingLocalClipKeys = new Set(options.preservingLocalClipKeys || state.dirtyClipRangeKeys || []);
    const deletedClipRangeKeys = new Set(state.deletedClipRangeKeys || []);
    const nextClipRanges = Object.fromEntries(Object.entries(state.clipRanges || {})
      .filter(([key]) => key.startsWith("local:") || preservingLocalClipKeys.has(key)));
    for (const payload of document.clip_ranges) {
      if (!payload || typeof payload.song_id !== "string") continue;
      const key = `remote:${payload.song_id}`;
      if (preservingLocalClipKeys.has(key) || deletedClipRangeKeys.has(key)) continue;
      const range = normalizeClipRange(payload.start_seconds, payload.end_seconds);
      if (range) nextClipRanges[key] = range;
    }
    state.clipRanges = nextClipRanges;
  }
  hydrateRemoteLikedTracks(state);
  return normalizeState(state);
}
