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
    remoteLikedSongIDs: [],
    dirtyRemoteLikeSongIDs: [],
    likesDirty: false,
    listeningHistory: [],
  };
}

function unique(values) {
  return [...new Set(values)];
}

function normalizedPlaylistID(value) {
  return String(value || "").toLocaleLowerCase();
}

function optionalHistoryText(value, maximumLength = 500) {
  const text = typeof value === "string" ? value.trim() : "";
  return text ? text.slice(0, maximumLength) : null;
}

function normalizeListeningHistoryEntry(entry, profileID = "default") {
  if (
    !entry
    || typeof entry !== "object"
    || typeof entry.id !== "string"
    || typeof (entry.trackID ?? entry.track_id) !== "string"
    || !Number.isFinite(Date.parse(entry.startedAt ?? entry.started_at))
  ) return null;
  const duration = Number(entry.duration ?? entry.duration_seconds);
  return {
    id: entry.id,
    trackID: entry.trackID ?? entry.track_id,
    profileID: typeof entry.profileID === "string" && entry.profileID
      ? entry.profileID
      : profileID,
    remoteID: optionalHistoryText(entry.remoteID ?? entry.songID ?? entry.song_id, 128),
    startedAt: new Date(entry.startedAt ?? entry.started_at).toISOString(),
    listenedSeconds: Math.max(0, Number(entry.listenedSeconds ?? entry.listened_seconds) || 0),
    title: optionalHistoryText(entry.title),
    artist: optionalHistoryText(entry.artist),
    album: optionalHistoryText(entry.album),
    duration: Number.isFinite(duration) && duration >= 0 ? duration : null,
  };
}

function limitListeningHistoryByProfile(entries, maximumPerProfile = 2000) {
  const byProfile = new Map();
  for (const entry of entries) {
    const profileID = entry.profileID || "default";
    if (!byProfile.has(profileID)) byProfile.set(profileID, []);
    byProfile.get(profileID).push(entry);
  }
  return [...byProfile.values()].flatMap((profileEntries) => profileEntries
    .sort((left, right) => Date.parse(left.startedAt) - Date.parse(right.startedAt))
    .slice(-maximumPerProfile));
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
  state.remoteLikedSongIDs = unique(Array.isArray(state.remoteLikedSongIDs) ? state.remoteLikedSongIDs.filter((id) => typeof id === "string" && id) : []);
  state.dirtyRemoteLikeSongIDs = unique(Array.isArray(state.dirtyRemoteLikeSongIDs) ? state.dirtyRemoteLikeSongIDs.filter((id) => typeof id === "string" && id) : []);
  state.likesDirty = Boolean(state.likesDirty);
  state.listeningHistory = limitListeningHistoryByProfile(
    (Array.isArray(state.listeningHistory) ? state.listeningHistory : [])
      .map((entry) => normalizeListeningHistoryEntry(entry))
      .filter(Boolean),
  );
  const seenRemote = new Set();
  state.tracks = state.tracks.filter((track) => !track.remoteID || (seenRemote.has(track.remoteID) ? false : (seenRemote.add(track.remoteID), true)));
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
  system.trackIDs = state.tracks.map((track) => track.id).filter((id) => favorites.has(id));
  return state;
}

export function mergeListeningHistory(state, profileID, remoteEntries) {
  const selectedProfileID = typeof profileID === "string" && profileID ? profileID : "default";
  const tracksByRemoteID = new Map(
    (state?.tracks || [])
      .filter((track) => track.remoteID && (track.syncProfileID || "default") === selectedProfileID)
      .map((track) => [track.remoteID, track]),
  );
  const localEntries = (Array.isArray(state?.listeningHistory) ? state.listeningHistory : [])
    .map((entry) => normalizeListeningHistoryEntry(entry))
    .filter(Boolean);
  const entriesByKey = new Map(localEntries.map((entry) => [`${entry.profileID}#${entry.id}`, entry]));

  for (const rawEntry of Array.isArray(remoteEntries) ? remoteEntries : []) {
    const normalized = normalizeListeningHistoryEntry(rawEntry, selectedProfileID);
    if (!normalized || normalized.profileID !== selectedProfileID) continue;
    const mappedTrack = normalized.remoteID ? tracksByRemoteID.get(normalized.remoteID) : null;
    if (mappedTrack) normalized.trackID = mappedTrack.id;
    const key = `${selectedProfileID}#${normalized.id}`;
    const existing = entriesByKey.get(key);
    entriesByKey.set(key, existing ? {
      ...existing,
      ...normalized,
      listenedSeconds: Math.max(existing.listenedSeconds, normalized.listenedSeconds),
      remoteID: normalized.remoteID ?? existing.remoteID,
      title: normalized.title ?? existing.title,
      artist: normalized.artist ?? existing.artist,
      album: normalized.album ?? existing.album,
      duration: normalized.duration ?? existing.duration,
    } : normalized);
  }

  return limitListeningHistoryByProfile([...entriesByKey.values()]);
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
      const songKey = entry.remoteID || entry.trackID;
      trackIDs.add(songKey);
      if (!songSeries.has(songKey)) {
        songSeries.set(songKey, {
          trackID: entry.trackID,
          remoteID: entry.remoteID,
          title: entry.title,
          artist: entry.artist,
          album: entry.album,
          seconds: 0,
          plays: 0,
          days: days.map((item) => ({ key: item.key, date: item.date, seconds: 0, plays: 0 })),
        });
      }
      const series = songSeries.get(songKey);
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

    const songKey = entry.remoteID || entry.trackID;
    const song = songs.get(songKey) || {
      trackID: entry.trackID,
      remoteID: entry.remoteID,
      title: entry.title,
      artist: entry.artist,
      album: entry.album,
      seconds: 0,
      plays: 0,
    };
    song.seconds += seconds;
    song.plays += 1;
    song.title ||= entry.title;
    song.artist ||= entry.artist;
    song.album ||= entry.album;
    songs.set(songKey, song);

    const artist = tracks.get(entry.trackID)?.artist?.trim() || entry.artist?.trim() || "Unknown artist";
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

export function mergeSyncedTracks(state, result) {
  const replaced = new Set(Array.isArray(result?.replacedTrackIDs) ? result.replacedTrackIDs : []);
  if (replaced.size) {
    state.tracks = state.tracks.filter((track) => !replaced.has(track.id));
  }
  state.tracks.push(...(Array.isArray(result?.downloaded) ? result.downloaded : []));
  hydrateRemotePlaylistTracks(state);
  hydrateRemoteLikedTracks(state);
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

export function hydrateRemoteLikedTracks(state) {
  const likedRemoteIDs = new Set(state.remoteLikedSongIDs);
  const localFavorites = state.favorites.filter((trackID) => {
    const track = state.tracks.find((item) => item.id === trackID);
    return track && !track.remoteID;
  });
  const remoteFavorites = state.tracks
    .filter((track) =>
      track.remoteID
      && (track.syncProfileID || "default") === state.syncProfileID
      && likedRemoteIDs.has(track.remoteID))
    .map((track) => track.id);
  state.favorites = unique([...localFavorites, ...remoteFavorites]);
  const system = state.playlists.find((playlist) => playlist.isSystem);
  if (system) system.trackIDs = state.tracks.map((track) => track.id).filter((id) => state.favorites.includes(id));
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
  return {
    document: { revision, playlists: merged, liked_song_ids: [...likedSongIDs] },
    needsUpload: needsUpload || state.dirtyRemoteLikeSongIDs.length > 0,
  };
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
  const remoteLikedSongIDs = new Set(unique(Array.isArray(document?.liked_song_ids) ? document.liked_song_ids : []));
  const intendedLikedSongIDs = new Set(state.remoteLikedSongIDs);
  for (const remoteID of state.dirtyRemoteLikeSongIDs) {
    if (intendedLikedSongIDs.has(remoteID)) remoteLikedSongIDs.add(remoteID);
    else remoteLikedSongIDs.delete(remoteID);
  }
  state.remoteLikedSongIDs = [...remoteLikedSongIDs];
  state.likesDirty = state.dirtyRemoteLikeSongIDs.length > 0;
  hydrateRemoteLikedTracks(state);
  return normalizeState(state);
}
