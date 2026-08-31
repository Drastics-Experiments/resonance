const LEGACY_PRODUCTION_ORIGIN = "https://music.unblocked.mov";
const PRODUCTION_ORIGIN = "https://resonance-core.blithe-haven-9710.chatgpt.site";
export const RESONANCE_ACCOUNT_SERVER_URL = `${PRODUCTION_ORIGIN}/`;

export const APP_THEMES = Object.freeze([
  Object.freeze({ id: "midnight", label: "Midnight", description: "Near-black with vivid violet." }),
  Object.freeze({ id: "ocean", label: "Ocean", description: "Deep blue with a bright cyan tide." }),
  Object.freeze({ id: "forest", label: "Forest", description: "Evergreen with a fresh mint glow." }),
  Object.freeze({ id: "sunset", label: "Sunset", description: "Warm ember with coral highlights." }),
]);
export const DEFAULT_APP_THEME = "midnight";
const APP_THEME_IDS = new Set(APP_THEMES.map(({ id }) => id));

export function normalizedAppTheme(value) {
  return typeof value === "string" && APP_THEME_IDS.has(value) ? value : DEFAULT_APP_THEME;
}

export function playableMediaDuration({ storedDuration, audioDuration, videoDuration } = {}) {
  const positive = (value) => {
    const number = Number(value);
    return Number.isFinite(number) && number > 0 ? number : null;
  };
  const playable = [positive(audioDuration), positive(videoDuration)].filter((value) => value !== null);
  return playable.length ? Math.min(...playable) : positive(storedDuration) || 0;
}

export function remoteMediaDuration(value) {
  const duration = Number(value);
  return Number.isFinite(duration) && duration > 0 && duration <= 24 * 60 * 60 ? duration : null;
}

export function downloadedSongMetadataRefreshSource(track) {
  if (!track?.available || !track.filePath) return null;
  const source = typeof track.sourceURL === "string" ? track.sourceURL.trim() : "";
  return source || null;
}

export function applyDownloadedSongMetadataRefresh(track, metadata, artwork = null) {
  const nonempty = (value, fallback) => {
    const text = typeof value === "string" ? value.trim() : "";
    return text || fallback;
  };
  return {
    ...track,
    title: nonempty(metadata?.title, track.title),
    artist: nonempty(metadata?.artist, track.artist),
    album: nonempty(metadata?.album, track.album),
    artworkURL: nonempty(metadata?.artworkURL, track.artworkURL || null),
    artwork: artwork || track.artwork || null,
  };
}

export function createEmptyState() {
  return {
    tracks: [],
    playlists: [{ id: "liked", name: "Liked Songs", trackIDs: [], isSystem: true }],
    favorites: [],
    serverURL: "https://resonance-core.blithe-haven-9710.chatgpt.site",
    volume: 0.78,
    playbackRate: 1,
    shuffle: false,
    repeat: false,
    currentTrackID: null,
    position: 0,
    playbackQueueIDs: [],
    playbackSourceQueueIDs: [],
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
    completedMigrations: [],
    serverUploadManifests: [],
    serverTransferPreferences: {},
    remoteSongMetadataCache: {},
    appPreferences: {
      theme: DEFAULT_APP_THEME,
      runInBackground: false,
      discordRichPresence: false,
      developerMode: false,
      crossfadeEnabled: false,
      crossfadeSeconds: 5,
      keybinds: {
        togglePlayback: "Space",
        previousTrack: "Ctrl+ArrowLeft",
        nextTrack: "Ctrl+ArrowRight",
        volumeDown: "Ctrl+ArrowDown",
        volumeUp: "Ctrl+ArrowUp",
      },
    },
  };
}

const REMOTE_SONG_METADATA_CACHE_LIFETIME_MS = 30 * 24 * 60 * 60 * 1000;
const REMOTE_SONG_METADATA_CACHE_LIMIT = 2_000;

function remoteSongMetadataSourceURL(value) {
  const source = typeof value === "string" ? value.trim() : "";
  if (!source || source.length > 8_192) return null;
  try {
    const url = new URL(source);
    if (url.protocol !== "https:" || url.username || url.password || url.hash) return null;
    return url.href;
  } catch {
    return null;
  }
}

function remoteSongMetadataText(value) {
  const text = typeof value === "string"
    ? value.replace(/[\u0000-\u001f]+/g, " ").replace(/\s+/g, " ").trim().slice(0, 500)
    : "";
  return text || null;
}

function remoteSongMetadataArtworkURL(value) {
  if (typeof value !== "string" || value.length > 2_048) return null;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password ? url.href : null;
  } catch {
    return null;
  }
}

export function remoteSongMetadataCacheKey(sourceURL, mediaKind = "audio") {
  const source = remoteSongMetadataSourceURL(sourceURL);
  return source ? `${mediaKind === "video" ? "video" : "audio"}:${source}` : null;
}

export function normalizedRemoteSongMetadataCache(value, now = Date.now()) {
  const currentTime = now instanceof Date ? now.getTime() : Number(now);
  const cutoff = (Number.isFinite(currentTime) ? currentTime : Date.now()) - REMOTE_SONG_METADATA_CACHE_LIFETIME_MS;
  const entries = [];
  if (value && typeof value === "object" && !Array.isArray(value)) {
    for (const item of Object.values(value)) {
      if (!item || typeof item !== "object" || Array.isArray(item)) continue;
      const sourceURL = remoteSongMetadataSourceURL(item.sourceURL);
      const mediaKind = item.mediaKind === "video" ? "video" : "audio";
      const key = remoteSongMetadataCacheKey(sourceURL, mediaKind);
      const title = remoteSongMetadataText(item.title);
      const artist = remoteSongMetadataText(item.artist);
      const cachedAtTime = Date.parse(item.cachedAt);
      if (!key || !title || !artist || !Number.isFinite(cachedAtTime) || cachedAtTime < cutoff) continue;
      const duration = Number(item.duration);
      entries.push([key, {
        sourceURL,
        mediaKind,
        title,
        artist,
        album: remoteSongMetadataText(item.album),
        duration: Number.isFinite(duration) && duration > 0 ? duration : null,
        artworkURL: remoteSongMetadataArtworkURL(item.artworkURL),
        cachedAt: new Date(cachedAtTime).toISOString(),
      }]);
    }
  }
  const normalized = {};
  let normalizedCount = 0;
  for (const [key, item] of entries.sort((left, right) => Date.parse(right[1].cachedAt) - Date.parse(left[1].cachedAt))) {
    if (Object.hasOwn(normalized, key)) continue;
    normalized[key] = item;
    normalizedCount += 1;
    if (normalizedCount >= REMOTE_SONG_METADATA_CACHE_LIMIT) break;
  }
  return normalized;
}

export function playlistArtworkTrackIDs(playlist) {
  if (!playlist || playlist.isSystem || !Array.isArray(playlist.trackIDs)) return [];
  return playlist.trackIDs.slice(0, 4);
}

const DEFAULT_KEYBINDS = Object.freeze({
  togglePlayback: "Space",
  previousTrack: "Ctrl+ArrowLeft",
  nextTrack: "Ctrl+ArrowRight",
  volumeDown: "Ctrl+ArrowDown",
  volumeUp: "Ctrl+ArrowUp",
});

function normalizedKeybind(value, fallback) {
  const candidate = typeof value === "string" ? value.trim().slice(0, 80) : "";
  return candidate || fallback;
}

export function normalizedAppPreferences(value) {
  const preferences = value && typeof value === "object" && !Array.isArray(value) ? value : {};
  const keybinds = preferences.keybinds && typeof preferences.keybinds === "object" && !Array.isArray(preferences.keybinds)
    ? preferences.keybinds
    : {};
  return {
    theme: normalizedAppTheme(preferences.theme),
    runInBackground: Boolean(preferences.runInBackground),
    discordRichPresence: Boolean(preferences.discordRichPresence),
    developerMode: Boolean(preferences.developerMode),
    crossfadeEnabled: Boolean(preferences.crossfadeEnabled),
    crossfadeSeconds: normalizedCrossfadeSeconds(preferences.crossfadeSeconds),
    keybinds: Object.fromEntries(Object.entries(DEFAULT_KEYBINDS).map(([action, fallback]) => [
      action,
      normalizedKeybind(keybinds[action], fallback),
    ])),
  };
}

export function normalizedCrossfadeSeconds(value) {
  const seconds = Number(value);
  return Number.isFinite(seconds) ? Math.max(1, Math.min(12, Math.round(seconds))) : 5;
}

export function serverTransferProgressPresentation(value = {}) {
  const usesItemProgress = Object.hasOwn(value, "itemCompleted")
    || Object.hasOwn(value, "itemTotal")
    || Object.hasOwn(value, "itemIndex")
    || Object.hasOwn(value, "itemCount");
  const completed = Math.max(0, Number(usesItemProgress ? value.itemCompleted : value.completed) || 0);
  const total = Math.max(0, Number(usesItemProgress ? value.itemTotal : value.total) || 0);
  const determinate = total > 0 && completed > 0;
  const ratio = determinate ? Math.min(1, completed / total) : null;
  const itemCount = Math.max(0, Math.floor(Number(value.itemCount) || 0));
  const itemIndex = Math.min(itemCount, Math.max(itemCount ? 1 : 0, Math.floor(Number(value.itemIndex) || 0)));
  const counter = itemCount ? `${itemIndex}/${itemCount}` : "";
  const percentage = ratio !== null && ratio > 0 && ratio < 0.01
    ? "<1%"
    : `${Math.round((ratio || 0) * 100)}%`;
  return {
    ratio,
    counter,
    determinate,
    label: determinate
      ? `${percentage}${counter ? ` \u00b7 ${counter}` : ""}`
      : completed > 0
        ? `Downloading${counter ? ` \u00b7 ${counter}` : "\u2026"}`
        : counter,
  };
}

export function crossfadeProgress(remainingSeconds, durationSeconds) {
  const duration = Number(durationSeconds);
  if (!Number.isFinite(duration) || duration <= 0) return 0;
  return Math.max(0, Math.min(1, 1 - (Number(remainingSeconds) || 0) / duration));
}

export function installedVideoSyncDecision({
  audioPlaying = false,
  videoPlaying = false,
  driftSeconds = 0,
  forceSeek = false,
  syncInFlight = false,
} = {}) {
  if (syncInFlight) return "none";
  const drift = Math.abs(Number(driftSeconds) || 0);
  if (forceSeek && drift > 0.005) return "seek";
  if (!audioPlaying) return videoPlaying ? "pause" : "none";
  return videoPlaying ? "none" : "play";
}

export function installedVideoCatchUpRate({
  audioRate = 1,
  audioPosition = 0,
  videoPosition = 0,
  enabled = true,
} = {}) {
  const baseline = Number(audioRate);
  if (!Number.isFinite(baseline) || baseline <= 0) return 1;
  const drift = Number(videoPosition) - Number(audioPosition);
  if (!enabled || !Number.isFinite(drift) || Math.abs(drift) <= 0.04) return baseline;
  const multiplier = Math.min(1.2, Math.max(0.85, Math.exp(-0.35 * drift)));
  return baseline * multiplier;
}

export const SAFE_CLIENT_CONFIG = Object.freeze({
  schema_version: 1,
  revision: 0,
  values: Object.freeze({
    "upload.local_file": true,
    "upload.server_source_link": false,
    "upload.reviewed_match": false,
    "upload.external_object": false,
    "download.offline_mode": "verified_file_cache",
    "download.playback_mode": "same_origin_resolver",
    "matcher.mode": "off",
    "storage.read_mode": "r2_only",
    "storage.r2_reclaim": false,
  }),
  kill_switches: Object.freeze({
    all_uploads: false,
    link_imports: true,
    offline_downloads: false,
    external_reads: true,
    r2_reclaim: true,
  }),
  source: "safe-defaults",
});

const UPLOAD_MODE_VALUES = new Set(["local_file", "server_source_link", "reviewed_match"]);
const DOWNLOAD_MODE_VALUES = new Set(["verified_file_cache", "stream_only"]);

export function canonicalYouTubeSourcePageURL(...values) {
  for (const value of values) {
    let url;
    try { url = new URL(String(value || "").trim()); }
    catch { continue; }
    if (url.protocol !== "https:" || url.username || url.password) continue;
    const hostname = url.hostname.toLocaleLowerCase().replace(/^www\./, "");
    let videoID = null;
    if (hostname === "youtu.be") videoID = url.pathname.split("/").filter(Boolean)[0];
    else if (["youtube.com", "m.youtube.com", "music.youtube.com"].includes(hostname)) {
      const segments = url.pathname.split("/").filter(Boolean);
      videoID = url.pathname === "/watch" ? url.searchParams.get("v")
        : ["embed", "live", "shorts"].includes(segments[0]) ? segments[1] : null;
    }
    if (/^[a-zA-Z0-9_-]{11}$/.test(videoID || "")) return `https://www.youtube.com/watch?v=${videoID}`;
  }
  return null;
}

export function exactYouTubeSourcePageURL(value) {
  const source = typeof value === "string" ? value.trim() : "";
  return /^https:\/\/www\.youtube\.com\/watch\?v=[A-Za-z0-9_-]{11}$/.test(source) ? source : null;
}

export function serverTransferPreferenceKey(serverURL, profileID = "default") {
  const origin = normalizedServerOrigin(serverURL);
  return origin ? `${origin}#profile=${String(profileID || "default").slice(0, 128)}` : "";
}

function normalizedServerTransferPreferences(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return Object.fromEntries(Object.entries(value).slice(0, 64).flatMap(([key, preference]) => {
    if (typeof key !== "string" || !key || key.length > 512 || !preference || typeof preference !== "object") return [];
    const uploadMode = UPLOAD_MODE_VALUES.has(preference.uploadMode) ? preference.uploadMode : "local_file";
    const downloadMode = DOWNLOAD_MODE_VALUES.has(preference.downloadMode) ? preference.downloadMode : "verified_file_cache";
    return [[key, { uploadMode, downloadMode }]];
  }));
}

export function activeServerClientConfig(config = SAFE_CLIENT_CONFIG, now = Date.now()) {
  if (!config || config === SAFE_CLIENT_CONFIG || config.verified !== true) return SAFE_CLIENT_CONFIG;
  const current = now instanceof Date ? now.getTime() : Number(now);
  const issuedAt = Date.parse(config.issued_at);
  const notBefore = Date.parse(config.not_before);
  const expiresAt = Date.parse(config.expires_at);
  if (!Number.isFinite(current)
    || !Number.isFinite(issuedAt)
    || !Number.isFinite(notBefore)
    || !Number.isFinite(expiresAt)
    || issuedAt > current
    || notBefore > current
    || current >= expiresAt
    || issuedAt > notBefore
    || notBefore >= expiresAt
    || expiresAt - issuedAt > 15 * 60 * 1000) return SAFE_CLIENT_CONFIG;
  return config;
}

export function clientConfigRenewalDelay(config = SAFE_CLIENT_CONFIG, now = Date.now(), {
  renewalLeadMs = 60_000,
  minimumDelayMs = 5_000,
  maximumDelayMs = 10 * 60_000,
  retryDelayMs = 60_000,
} = {}) {
  const current = now instanceof Date ? now.getTime() : Number(now);
  if (!Number.isFinite(current) || activeServerClientConfig(config, current) === SAFE_CLIENT_CONFIG) {
    return retryDelayMs;
  }
  const expiresAt = Date.parse(config.expires_at);
  return Math.max(minimumDelayMs, Math.min(maximumDelayMs, expiresAt - current - renewalLeadMs));
}

export function persistentPlaybackIDs(trackIDs, tracks) {
  const persistent = new Set((Array.isArray(tracks) ? tracks : [])
    .filter((track) => track && track.transientStream !== true && typeof track.id === "string")
    .map((track) => track.id));
  return [...new Set(Array.isArray(trackIDs) ? trackIDs : [])].filter((id) => persistent.has(id));
}

export function availableServerTransferModes(
  config = SAFE_CLIENT_CONFIG,
  now = Date.now(),
  { localImportAvailable = true } = {},
) {
  const activeConfig = activeServerClientConfig(config, now);
  const values = activeConfig.values;
  const kills = activeConfig.kill_switches;
  const upload = [];
  const localFileUpload = !kills.all_uploads && values["upload.local_file"] === true;
  if (localFileUpload) upload.push("local_file");
  if (!kills.all_uploads && !kills.link_imports && values["upload.server_source_link"] === true) upload.push("server_source_link");
  if (localImportAvailable
      && localFileUpload
      && values["upload.reviewed_match"] === true
      && values["matcher.mode"] === "review") upload.push("reviewed_match");
  const requestedDownloadMode = values["download.offline_mode"];
  const download = requestedDownloadMode === "stream_only"
    ? ["stream_only"]
    : (!kills.offline_downloads && requestedDownloadMode === "verified_file_cache" ? ["verified_file_cache"] : ["stream_only"]);
  return { upload, download };
}

export function resolveServerTransferModes({
  state,
  serverURL,
  profileID,
  config = SAFE_CLIENT_CONFIG,
  now = Date.now(),
  localImportAvailable = true,
} = {}) {
  const available = availableServerTransferModes(config, now, { localImportAvailable });
  const key = serverTransferPreferenceKey(serverURL, profileID);
  const preferences = normalizedServerTransferPreferences(state?.serverTransferPreferences);
  const selected = key ? preferences[key] : null;
  return {
    key,
    available,
    uploadMode: available.upload.includes(selected?.uploadMode) ? selected.uploadMode : (available.upload[0] || null),
    downloadMode: available.download.includes(selected?.downloadMode) ? selected.downloadMode : available.download[0],
  };
}

export function setServerTransferPreference(state, { serverURL, profileID, uploadMode, downloadMode, config = SAFE_CLIENT_CONFIG, now = Date.now() } = {}) {
  if (!state || typeof state !== "object") return resolveServerTransferModes({ state, serverURL, profileID, config, now });
  const resolved = resolveServerTransferModes({ state, serverURL, profileID, config, now });
  if (!resolved.key) return resolved;
  state.serverTransferPreferences = normalizedServerTransferPreferences(state.serverTransferPreferences);
  state.serverTransferPreferences[resolved.key] = {
    uploadMode: resolved.available.upload.includes(uploadMode) ? uploadMode : resolved.uploadMode,
    downloadMode: resolved.available.download.includes(downloadMode) ? downloadMode : resolved.downloadMode,
  };
  return resolveServerTransferModes({ state, serverURL, profileID, config, now });
}

export function titleMarqueeMetrics(contentWidth, availableWidth, loopSpacing = 56) {
  const content = Number.isFinite(Number(contentWidth)) ? Math.max(Number(contentWidth), 0) : 0;
  const available = Number.isFinite(Number(availableWidth)) ? Math.max(Number(availableWidth), 0) : 0;
  const travel = Math.max(content - available, 0);
  const cycleDistance = travel > 0 ? content + Math.max(Number(loopSpacing) || 0, 0) : 0;
  return {
    travel,
    cycleDistance,
    durationSeconds: cycleDistance > 0 ? Math.max(8, cycleDistance / 28) : 0,
  };
}

export function isInstalledVideoTrack(track) {
  const fileURL = String(track?.fileUrl || "").trim();
  if (!/^file:/i.test(fileURL)) return false;
  const source = String(track?.filePath || fileURL).split(/[?#]/, 1)[0];
  return /\.(?:mp4|mov|m4v|webm)$/i.test(source);
}

export function serverSongRequiresDownload(song) {
  if (song?.media_kind === "video" || song?.mediaKind === "video") return true;
  const contentType = String(song?.content_type || song?.contentType || "")
    .split(";", 1)[0]
    .trim()
    .toLowerCase();
  if (contentType.startsWith("video/")) return true;
  const filename = String(song?.filename || song?.name || "").split(/[?#]/, 1)[0];
  return /\.(?:avi|mkv|mov|mp4|m4v|webm)$/i.test(filename);
}

export function serverSourceNeedsOriginalPage(sourceURL) {
  try {
    const url = new URL(String(sourceURL || ""));
    const host = url.hostname.toLocaleLowerCase();
    return host === "googlevideo.com"
      || host.endsWith(".googlevideo.com")
      || url.pathname.split("/").pop()?.toLocaleLowerCase() === "videoplayback";
  } catch {
    return false;
  }
}

export function serverSourceDisplayFallback(sourceURL) {
  if (serverSourceNeedsOriginalPage(sourceURL)) {
    return {
      title: "Original source link needed",
      artist: "Re-import on the original device",
      album: "Legacy expired link",
    };
  }
  return { title: "Resolving metadata…", artist: "Automatic lookup", album: "Link only" };
}

export function localImportOperationFingerprint({ source, mediaKind, selection = [], uploadRequested = false } = {}) {
  const normalizedSource = String(source || "").trim();
  const normalizedKind = mediaKind === "video" ? "video" : "audio";
  const normalizedSelection = (Array.isArray(selection) ? selection : [])
    .map((value) => String(value))
    .sort();
  return JSON.stringify([normalizedKind, normalizedSource, normalizedSelection, Boolean(uploadRequested)]);
}

export function localImportOperationIsCurrent(snapshot, current) {
  return Boolean(
    snapshot
    && current
    && Number.isSafeInteger(snapshot.generation)
    && snapshot.generation === current.generation
    && snapshot.fingerprint === current.fingerprint,
  );
}

export function squareArtworkCropRect(
  pixels,
  sampleWidth,
  sampleHeight,
  sourceWidth = sampleWidth,
  sourceHeight = sampleHeight,
) {
  const width = Math.max(1, Math.floor(Number(sampleWidth) || 0));
  const height = Math.max(1, Math.floor(Number(sampleHeight) || 0));
  const naturalWidth = Math.max(1, Number(sourceWidth) || width);
  const naturalHeight = Math.max(1, Number(sourceHeight) || height);
  const centeredSquare = () => {
    const side = Math.min(naturalWidth, naturalHeight);
    return {
      x: (naturalWidth - side) / 2,
      y: (naturalHeight - side) / 2,
      width: side,
      height: side,
    };
  };
  if (!pixels || pixels.length < width * height * 4) return centeredSquare();

  const bytesPerPixel = 4;
  const bytesPerRow = width * bytesPerPixel;
  const stats = (offsets) => {
    if (!offsets.length) return { channels: [0, 0, 0, 0], deviation: 255 };
    const totals = [0, 0, 0, 0];
    for (const offset of offsets) {
      for (let channel = 0; channel < bytesPerPixel; channel += 1) totals[channel] += pixels[offset + channel];
    }
    const channels = totals.map((total) => total / offsets.length);
    let totalDeviation = 0;
    for (const offset of offsets) {
      for (let channel = 0; channel < bytesPerPixel; channel += 1) {
        totalDeviation += Math.abs(pixels[offset + channel] - channels[channel]);
      }
    }
    return { channels, deviation: totalDeviation / (offsets.length * bytesPerPixel) };
  };
  const rowStats = (row) => stats(Array.from({ length: width }, (_, column) => row * bytesPerRow + column * bytesPerPixel));
  const columnStats = (column, startRow, endRow) => stats(Array.from(
    { length: Math.max(0, endRow - startRow) },
    (_, row) => (row + startRow) * bytesPerRow + column * bytesPerPixel,
  ));
  const colorDistance = (left, right) => left.channels.reduce(
    (total, channel, index) => total + Math.abs(channel - right.channels[index]),
    0,
  ) / bytesPerPixel;
  const borderRun = (lineCount, statsAt, fromStart) => {
    if (lineCount < 6) return 0;
    const reference = statsAt(fromStart ? 0 : lineCount - 1);
    if (reference.deviation > 10) return 0;
    let count = 0;
    for (let offset = 0; offset < Math.floor(lineCount / 2); offset += 1) {
      const index = fromStart ? offset : lineCount - 1 - offset;
      const candidate = statsAt(index);
      if (candidate.deviation > 13 || colorDistance(candidate, reference) > 18) break;
      count += 1;
    }
    return count;
  };
  const symmetricInsets = (first, second, length) => {
    if (first < 2 || second < 2 || first + second >= length * 3 / 4) return [0, 0];
    const tolerance = Math.max(2, Math.floor(Math.min(first, second) / 3));
    return Math.abs(first - second) <= tolerance ? [first, second] : [0, 0];
  };

  const [top, bottom] = symmetricInsets(
    borderRun(height, rowStats, true),
    borderRun(height, rowStats, false),
    height,
  );
  const contentEndRow = height - bottom;
  const statsForColumn = (column) => columnStats(column, top, contentEndRow);
  const [left, right] = symmetricInsets(
    borderRun(width, statsForColumn, true),
    borderRun(width, statsForColumn, false),
    width,
  );

  const scaleX = naturalWidth / width;
  const scaleY = naturalHeight / height;
  const content = {
    x: left * scaleX,
    y: top * scaleY,
    width: (width - left - right) * scaleX,
    height: (height - top - bottom) * scaleY,
  };
  const side = Math.min(content.width, content.height);
  if (!(side > 0)) return centeredSquare();
  return {
    x: Math.max(0, Math.min(naturalWidth - side, content.x + (content.width - side) / 2)),
    y: Math.max(0, Math.min(naturalHeight - side, content.y + (content.height - side) / 2)),
    width: side,
    height: side,
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
    const origin = new URL(String(value || "").trim()).origin;
    return origin === LEGACY_PRODUCTION_ORIGIN ? PRODUCTION_ORIGIN : origin;
  } catch {
    return "";
  }
}

function canonicalServerURL(value) {
  try {
    const url = new URL(String(value || "").trim());
    if (url.origin === LEGACY_PRODUCTION_ORIGIN && url.pathname === "/" && !url.search && !url.hash) {
      return PRODUCTION_ORIGIN;
    }
  } catch {}
  return value;
}

function canonicalProfileStateKey(value) {
  const key = String(value || "");
  const marker = "#profile=";
  const boundary = key.indexOf(marker);
  if (boundary < 0) return normalizedServerOrigin(key) || key;
  const origin = normalizedServerOrigin(key.slice(0, boundary));
  return origin ? origin + key.slice(boundary) : key;
}

function normalizedServerSongIdentityText(value) {
  return String(value || "")
    .normalize("NFKD")
    .replace(/\p{M}+/gu, "")
    .toLocaleLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
}

function serverSongArtistTokens(value) {
  const connectors = new Set(["and", "feat", "featuring", "ft", "with"]);
  const placeholders = new Set(["unknown", "artist", "local", "file"]);
  return new Set(normalizedServerSongIdentityText(value)
    .split(" ")
    .filter(Boolean)
    .filter((token) => !connectors.has(token) && !placeholders.has(token)));
}

export function serverSongMetadataMatches(track, song) {
  if (normalizedServerSongIdentityText(track?.title) !== normalizedServerSongIdentityText(song?.title)) return false;
  const trackArtists = serverSongArtistTokens(track?.artist);
  const songArtists = serverSongArtistTokens(song?.artist);
  if (!trackArtists.size || trackArtists.size !== songArtists.size) return false;
  if ([...trackArtists].some((token) => !songArtists.has(token))) return false;
  const trackDuration = Number(track?.duration);
  const songDuration = Number(song?.duration_seconds ?? song?.durationSeconds ?? song?.duration);
  return !(trackDuration > 0 && songDuration > 0) || Math.abs(trackDuration - songDuration) <= 5;
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

function optionalHistoryText(value, maximumLength = 500) {
  const text = typeof value === "string" ? value.trim() : "";
  return text ? text.slice(0, maximumLength) : null;
}

function normalizedHistoryDuration(value) {
  if (value === null || value === undefined || value === "") return null;
  const duration = Number(value);
  return Number.isFinite(duration) && duration >= 0 && duration <= 7 * 24 * 60 * 60 ? duration : null;
}

function boundedUploadText(value, maximumLength = 500) {
  const text = typeof value === "string" ? value.trim() : "";
  return text ? text.slice(0, maximumLength) : null;
}

function normalizedServerUploadManifestItem(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const status = ["uploaded", "failed", "cancelled"].includes(value.status) ? value.status : null;
  const title = boundedUploadText(value.title) || boundedUploadText(value.filename) || "Untitled song";
  if (!status) return null;
  return {
    retryID: boundedUploadText(value.retryID, 128),
    trackID: boundedUploadText(value.trackID, 128),
    filename: boundedUploadText(value.filename),
    title,
    artist: boundedUploadText(value.artist),
    status,
    attempts: Math.max(0, Math.min(10, Math.floor(Number(value.attempts) || 0))),
    message: status === "uploaded" ? null : boundedUploadText(value.message, 1_000) || (status === "cancelled" ? "Upload cancelled." : "Upload failed."),
    remoteID: boundedUploadText(value.remoteID, 128),
  };
}

export function normalizeServerUploadManifest(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const id = boundedUploadText(value.id, 128);
  const serverOrigin = normalizedServerOrigin(value.serverOrigin);
  const items = (Array.isArray(value.items) ? value.items : [])
    .map(normalizedServerUploadManifestItem)
    .filter(Boolean)
    .slice(0, 500);
  if (!id || !serverOrigin || !items.length) return null;
  const startedAt = Number.isFinite(Date.parse(value.startedAt))
    ? new Date(value.startedAt).toISOString()
    : new Date().toISOString();
  const updatedAt = Number.isFinite(Date.parse(value.updatedAt))
    ? new Date(value.updatedAt).toISOString()
    : startedAt;
  return {
    id,
    serverOrigin,
    profileID: boundedUploadText(value.profileID, 128) || "default",
    source: ["picker", "missing-downloads", "link-import"].includes(value.source) ? value.source : "picker",
    startedAt,
    updatedAt,
    items,
  };
}

export function serverUploadManifestRetryIDs(value) {
  const manifest = normalizeServerUploadManifest(value);
  return manifest ? manifest.items
    .filter((item) => item.status !== "uploaded" && item.retryID)
    .map((item) => item.retryID) : [];
}

export function serverUploadManifestCanCleanup(value) {
  const manifest = normalizeServerUploadManifest(value);
  return Boolean(manifest?.items.length) && manifest.items.every((item) => item.status === "uploaded");
}

export function physicalStorageClassForTrack(track) {
  if (track?.storageLocation === "server-cache") return "downloads";
  if (track?.storageLocation === "external") return "external";
  if (track?.storageLocation === "local") return "files";
  // Legacy normalized state may be constructed outside the main process. The
  // main-process loader replaces this fallback with the path-derived class.
  return track?.remoteID ? "downloads" : "files";
}

function listeningHistorySongKey(entry) {
  const profileID = entry?.profileID || "default";
  const serverOrigin = normalizedServerOrigin(entry?.serverOrigin) || "unowned";
  const remoteID = optionalHistoryText(entry?.remoteID, 128);
  return remoteID
    ? `${serverOrigin}#${profileID}#remote:${remoteID}`
    : `${serverOrigin}#${profileID}#track:${entry?.trackID || "unknown"}`;
}

function listeningHistoryArtworkURL(value, serverURL) {
  const origin = normalizedServerOrigin(serverURL);
  if (!origin || typeof value !== "string" || value.length > 2_048) return null;
  try {
    const url = new URL(value, `${origin}/`);
    return url.protocol === "https:"
      && url.origin === origin
      && !url.username
      && !url.password
      ? url.href
      : null;
  } catch {
    return null;
  }
}

function listeningHistoryMetadataPlaceholder(value, field) {
  const normalized = String(value || "").trim().replaceAll("…", "...").toLocaleLowerCase();
  if (!normalized) return true;
  if (field === "title") {
    return normalized === "resolving metadata..."
      || normalized === "unknown song"
      || normalized === "untitled"
      || normalized.startsWith("saved song ");
  }
  if (field === "artist") {
    return normalized === "automatic lookup" || normalized === "unknown artist";
  }
  return normalized === "link only"
    || normalized === "unknown album"
    || normalized === "server library";
}

function preferredListeningHistoryMetadata(field, ...values) {
  for (const value of values) {
    const text = optionalHistoryText(value);
    if (text && !listeningHistoryMetadataPlaceholder(text, field)) return text;
  }
  return null;
}

export function serverSongHasCatalogMetadata(song) {
  return Boolean(
    preferredListeningHistoryMetadata("title", song?.title, song?.name)
    && preferredListeningHistoryMetadata("artist", song?.artist),
  );
}

export function hydrateListeningHistoryFromCatalog(
  state,
  catalog = [],
  requestedProfileID = state?.syncProfileID || "default",
  requestedServerURL = state?.serverURL,
) {
  const requestedServerOrigin = normalizedServerOrigin(requestedServerURL);
  if (!requestedServerOrigin || !Array.isArray(state?.listeningHistory)) return false;
  const songsByRemoteID = new Map((Array.isArray(catalog) ? catalog : [])
    .filter((song) => optionalHistoryText(song?.id, 128))
    .map((song) => [String(song.id), song]));
  let changed = false;
  for (const entry of state.listeningHistory) {
    if ((entry?.profileID || "default") !== requestedProfileID
        || normalizedServerOrigin(entry?.serverOrigin) !== requestedServerOrigin) continue;
    const remoteID = optionalHistoryText(entry?.remoteID, 128);
    const song = remoteID ? songsByRemoteID.get(remoteID) : null;
    if (!song) continue;
    const nextTitle = preferredListeningHistoryMetadata(
      "title", song.title, song.name, song.filename, entry.title,
    );
    const nextArtist = preferredListeningHistoryMetadata("artist", song.artist, entry.artist);
    const nextAlbum = preferredListeningHistoryMetadata("album", song.album, entry.album);
    const catalogDuration = normalizedHistoryDuration(song.duration_seconds ?? song.duration);
    const nextDuration = catalogDuration > 0 ? catalogDuration : entry.duration;
    const nextArtworkURL = listeningHistoryArtworkURL(
      song.artwork_url ?? song.artworkURL ?? entry.artworkURL,
      requestedServerOrigin,
    );
    if (entry.title !== nextTitle
        || entry.artist !== nextArtist
        || entry.album !== nextAlbum
        || entry.duration !== nextDuration
        || entry.artworkURL !== nextArtworkURL) {
      entry.title = nextTitle;
      entry.artist = nextArtist;
      entry.album = nextAlbum;
      entry.duration = nextDuration;
      entry.artworkURL = nextArtworkURL;
      changed = true;
    }
  }
  return changed;
}

function listeningHistoryTrackSnapshot(state, entry) {
  const profileID = entry?.profileID || "default";
  const remoteID = optionalHistoryText(entry?.remoteID, 128);
  const activeTracks = tracksForActiveProfile(state);
  const identityTrack = activeTracks.find((item) => item?.id === entry?.trackID)
    || (remoteID ? activeTracks.find((item) =>
      item?.remoteID === remoteID && (item.syncProfileID || "default") === profileID) : null);
  const localMetadataMatches = identityTrack ? [] : activeTracks.filter((item) =>
    !item?.remoteID
      && (item?.filePath || item?.fileUrl)
      && serverSongMetadataMatches(item, {
        title: entry?.title,
        artist: entry?.artist,
        duration: entry?.duration,
      }));
  const track = identityTrack || (localMetadataMatches.length === 1 ? localMetadataMatches[0] : null);
  const trackDuration = normalizedHistoryDuration(track?.duration);
  const entryDuration = normalizedHistoryDuration(entry?.duration);
  return {
    id: track?.id || entry?.trackID,
    remoteID: track?.remoteID || remoteID,
    title: preferredListeningHistoryMetadata("title", track?.title, entry?.title) || "Unknown song",
    artist: preferredListeningHistoryMetadata("artist", track?.artist, entry?.artist) || "Unknown artist",
    album: preferredListeningHistoryMetadata("album", track?.album, entry?.album) || "Unknown Album",
    duration: trackDuration && trackDuration > 0 ? trackDuration : entryDuration ?? 0,
    artwork: track?.artwork || null,
    artworkURL: listeningHistoryArtworkURL(
      track?.artworkURL || entry?.artworkURL,
      entry?.serverOrigin || state?.serverURL,
    ),
    fileUrl: track?.fileUrl || null,
  };
}

export function listeningHistoryEntryQualifiesAsPlay(state, entry) {
  const listenedSeconds = Number(entry?.listenedSeconds);
  if (!Number.isFinite(listenedSeconds) || listenedSeconds <= 0) return false;
  const duration = listeningHistoryTrackSnapshot(state, entry).duration;
  return Number.isFinite(duration) && duration > 0 && listenedSeconds > duration * 0.1;
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
      entryOrder: normalizedPlaylistEntryOrder(playlist.entryOrder),
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
    playlistSyncServerURL: typeof value.playlistSyncServerURL === "string"
      ? canonicalProfileStateKey(value.playlistSyncServerURL)
      : null,
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

export function migrateProfileContext(state, serverURL, migratedProfileID, accountProfileID) {
  const oldProfileID = String(migratedProfileID || "").trim();
  const nextProfileID = String(accountProfileID || "").trim();
  const migrationOrigin = normalizedServerOrigin(serverURL);
  if (!oldProfileID || !nextProfileID || oldProfileID === nextProfileID || !migrationOrigin) return false;
  if (normalizedServerOrigin(state.serverURL) !== migrationOrigin || state.syncProfileID !== oldProfileID) return false;

  storeActiveProfileState(state);
  const oldKey = profileStateKey(serverURL, oldProfileID);
  const nextKey = profileStateKey(serverURL, nextProfileID);
  const snapshot = normalizedProfileState(state.profileStates[oldKey]);
  snapshot.playlistSyncServerURL = snapshot.playlistSyncServerURL === oldKey
    ? nextKey
    : snapshot.playlistSyncServerURL;
  state.profileStates[nextKey] = snapshot;
  delete state.profileStates[oldKey];

  state.tracks = (state.tracks || []).map((track) =>
    track?.remoteID
      && normalizedServerOrigin(track.sourceServer) === migrationOrigin
      && (track.syncProfileID || "default") === oldProfileID
      ? { ...track, syncProfileID: nextProfileID }
      : track);
  state.listeningHistory = (state.listeningHistory || []).map((entry) =>
    normalizedServerOrigin(entry?.serverOrigin) === migrationOrigin
      && (entry.profileID || "default") === oldProfileID
      ? { ...entry, profileID: nextProfileID }
      : entry);
  state.serverUploadManifests = (state.serverUploadManifests || []).map((manifest) =>
    normalizedServerOrigin(manifest?.serverOrigin) === migrationOrigin
      && (manifest.profileID || "default") === oldProfileID
      ? { ...manifest, profileID: nextProfileID }
      : manifest);
  if (state.playlistSyncServerURL === oldKey) state.playlistSyncServerURL = nextKey;
  if (state.serverTransferPreferences?.[oldKey]) {
    state.serverTransferPreferences[nextKey] ??= state.serverTransferPreferences[oldKey];
    delete state.serverTransferPreferences[oldKey];
  }
  state.syncProfileID = nextProfileID;
  state.serverURL = serverURL;
  return true;
}

export function trackBelongsToActiveProfile(state, track) {
  if (!track?.remoteID) return true;
  const activeServer = normalizedServerOrigin(state.serverURL);
  const source = normalizedServerOrigin(track.sourceServer);
  const profileMatches = (track.syncProfileID || "default") === (state.syncProfileID || "default");
  return profileMatches && Boolean(source && activeServer && source === activeServer);
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
  state.serverURL = canonicalServerURL(state.serverURL);
  state.tracks = Array.isArray(state.tracks) ? state.tracks : [];
  state.playlists = Array.isArray(state.playlists) ? state.playlists : [];
  state.favorites = Array.isArray(state.favorites) ? state.favorites : [];
  state.playlistRevision = Number.isInteger(state.playlistRevision) && state.playlistRevision >= 0 ? state.playlistRevision : 0;
  state.knownRemotePlaylistIDs = unique(Array.isArray(state.knownRemotePlaylistIDs) ? state.knownRemotePlaylistIDs.map(normalizedPlaylistID) : []);
  state.dirtyPlaylistIDs = unique(Array.isArray(state.dirtyPlaylistIDs) ? state.dirtyPlaylistIDs.map(normalizedPlaylistID) : []);
  state.deletedPlaylistIDs = unique(Array.isArray(state.deletedPlaylistIDs) ? state.deletedPlaylistIDs.map(normalizedPlaylistID) : []);
  state.playlistSyncServerURL = typeof state.playlistSyncServerURL === "string"
    ? canonicalProfileStateKey(state.playlistSyncServerURL)
    : null;
  state.syncProfileID = typeof state.syncProfileID === "string" && state.syncProfileID ? state.syncProfileID : "default";
  state.syncProfiles = Array.isArray(state.syncProfiles) && state.syncProfiles.length
    ? state.syncProfiles
    : [{ id: "default", name: "Default", is_default: true }];
  if (state.profileStates && typeof state.profileStates === "object") {
    const canonicalStates = {};
    for (const [key, snapshot] of Object.entries(state.profileStates)) {
      const canonicalKey = canonicalProfileStateKey(key);
      if (canonicalKey === key) canonicalStates[canonicalKey] = normalizedProfileState(snapshot);
    }
    for (const [key, snapshot] of Object.entries(state.profileStates)) {
      const canonicalKey = canonicalProfileStateKey(key);
      if (!(canonicalKey in canonicalStates)) canonicalStates[canonicalKey] = normalizedProfileState(snapshot);
    }
    state.profileStates = canonicalStates;
  } else {
    state.profileStates = {};
  }
  state.remoteLikedSongIDs = unique(Array.isArray(state.remoteLikedSongIDs) ? state.remoteLikedSongIDs.filter((id) => typeof id === "string" && id) : []);
  state.dirtyRemoteLikeSongIDs = unique(Array.isArray(state.dirtyRemoteLikeSongIDs) ? state.dirtyRemoteLikeSongIDs.filter((id) => typeof id === "string" && id) : []);
  state.likesDirty = Boolean(state.likesDirty);
  state.clipRanges = normalizedClipRanges(state.clipRanges);
  state.dirtyClipRangeKeys = unique(Array.isArray(state.dirtyClipRangeKeys) ? state.dirtyClipRangeKeys.filter((key) => typeof key === "string" && key.startsWith("remote:")) : []);
  state.deletedClipRangeKeys = unique(Array.isArray(state.deletedClipRangeKeys) ? state.deletedClipRangeKeys.filter((key) => typeof key === "string" && key.startsWith("remote:")) : []);
  const historyOriginByTrackID = new Map();
  for (const track of state.tracks) {
    if (!track || typeof track !== "object") continue;
    const origin = normalizedServerOrigin(track.sourceServer);
    if (track.id && origin) historyOriginByTrackID.set(track.id, origin);
  }
  const inferredHistoryOrigin = (entry) => {
    const explicit = normalizedServerOrigin(entry?.serverOrigin);
    if (explicit) return explicit;
    // A bare remote ID is not globally unique. Only the referenced track's
    // persisted origin can safely migrate a legacy history entry.
    return historyOriginByTrackID.get(entry?.trackID) || null;
  };
  state.listeningHistory = (Array.isArray(state.listeningHistory) ? state.listeningHistory : [])
    .filter((entry) =>
      entry
      && typeof entry.id === "string"
      && typeof entry.trackID === "string"
      && entry.id.length <= 128
      && entry.trackID.length <= 128
      && Number.isFinite(Date.parse(entry.startedAt)))
    .map((entry) => ({
      id: entry.id,
      trackID: entry.trackID,
      profileID: typeof entry.profileID === "string" && entry.profileID ? entry.profileID : "default",
      serverOrigin: inferredHistoryOrigin(entry),
      startedAt: new Date(entry.startedAt).toISOString(),
      listenedSeconds: Math.max(0, Number(entry.listenedSeconds) || 0),
      remoteID: optionalHistoryText(entry.remoteID, 128),
      title: optionalHistoryText(entry.title),
      artist: optionalHistoryText(entry.artist),
      album: optionalHistoryText(entry.album),
      duration: normalizedHistoryDuration(entry.duration),
      artworkURL: listeningHistoryArtworkURL(entry.artworkURL, inferredHistoryOrigin(entry)),
      originatedOnThisDevice: entry.originatedOnThisDevice !== false,
    }))
    .slice(-2000);
  state.completedMigrations = unique(
    (Array.isArray(state.completedMigrations) ? state.completedMigrations : [])
      .filter((item) => typeof item === "string" && item.length <= 100),
  );
  state.serverUploadManifests = (Array.isArray(state.serverUploadManifests) ? state.serverUploadManifests : [])
    .map(normalizeServerUploadManifest)
    .filter(Boolean)
    .slice(-20);
  state.serverTransferPreferences = normalizedServerTransferPreferences(state.serverTransferPreferences);
  state.remoteSongMetadataCache = normalizedRemoteSongMetadataCache(state.remoteSongMetadataCache);
  state.appPreferences = normalizedAppPreferences(state.appPreferences);
  state.tracks = state.tracks.map((track) => track?.remoteID ? {
    ...track,
    // A source-less legacy remote record has ambiguous ownership. Keep it
    // quarantined until an exact compound identity or content hash proves its
    // server instead of assigning whichever server happens to be configured.
    sourceServer: normalizedServerOrigin(track.sourceServer) || null,
    syncProfileID: track.syncProfileID || "default",
    available: track.available !== false,
    missing: Boolean(track.missing || track.available === false),
    storageLocation: typeof track.storageLocation === "string" ? track.storageLocation : "server-cache",
  } : {
    ...track,
    available: track?.available !== false,
    missing: Boolean(track?.missing || track?.available === false),
    storageLocation: typeof track?.storageLocation === "string" ? track.storageLocation : "local",
  });
  reconcileServerBackedTrackDuplicates(state);
  const seenRemote = new Set();
  state.tracks = state.tracks.filter((track) => {
    if (!track?.remoteID) return true;
    const sourceServer = normalizedServerOrigin(track.sourceServer);
    // Source-less legacy records have no proven compound identity. Preserve
    // each local record until a later exact association can reconcile it.
    if (!sourceServer) return true;
    const key = `${sourceServer}#${track.syncProfileID}#${track.remoteID}`;
    if (seenRemote.has(key)) return false;
    seenRemote.add(key);
    return true;
  });
  const trackIDs = new Set(state.tracks.map((track) => track.id));
  state.playbackQueueIDs = unique(Array.isArray(state.playbackQueueIDs) ? state.playbackQueueIDs : [])
    .filter((id) => trackIDs.has(id));
  state.playbackSourceQueueIDs = unique(Array.isArray(state.playbackSourceQueueIDs)
    ? state.playbackSourceQueueIDs
    : state.playbackQueueIDs)
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
    playlist.entryOrder = normalizedPlaylistEntryOrder(playlist.entryOrder);
  });
  const favorites = new Set(state.favorites);
  if (!hadRemoteLikedSongIDs) {
    state.remoteLikedSongIDs = unique(state.tracks
      .filter((track) => track.remoteID && favorites.has(track.id) && trackBelongsToActiveProfile(state, track))
      .map((track) => track.remoteID));
  }
  if (state.likesDirty && !hadDirtyRemoteLikeSongIDs) {
    state.dirtyRemoteLikeSongIDs = unique(state.tracks
      .filter((track) => track.remoteID && trackBelongsToActiveProfile(state, track))
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
  const activeServerOrigin = normalizedServerOrigin(state?.serverURL);
  const entryServerOrigin = normalizedServerOrigin(entry?.serverOrigin);
  if (entryProfileID !== activeProfileID) return false;
  // A library that has never been connected to a server still owns its local
  // history. Once a server is configured, unowned legacy entries stay private
  // instead of being silently attributed to (and synced with) that server.
  if (!activeServerOrigin) return !entryServerOrigin;
  return Boolean(entryServerOrigin && activeServerOrigin === entryServerOrigin);
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
  const songKeys = new Set();
  const songSeries = new Map();
  const todayKey = localDayKey(now);
  let todaySeconds = 0;
  let todayPlays = 0;
  for (const entry of state?.listeningHistory || []) {
    if (!listeningHistoryEntryMatchesActiveProfile(state, entry)) continue;
    const timestamp = Date.parse(entry.startedAt);
    if (!Number.isFinite(timestamp)) continue;
    const seconds = Math.max(0, Number(entry.listenedSeconds) || 0);
    const qualifiesAsPlay = listeningHistoryEntryQualifiesAsPlay(state, entry);
    if (localDayKey(timestamp) === todayKey) {
      todaySeconds += seconds;
      if (qualifiesAsPlay) todayPlays += 1;
    }
    const key = hourly ? hourKey(timestamp) : localDayKey(timestamp);
    const day = byKey.get(key);
    if (!day) continue;
    day.seconds += seconds;
    if (qualifiesAsPlay) day.plays += 1;
    if (entry.trackID) {
      const songKey = listeningHistorySongKey(entry);
      const snapshot = listeningHistoryTrackSnapshot(state, entry);
      songKeys.add(songKey);
      if (!songSeries.has(songKey)) {
        songSeries.set(songKey, {
          trackID: snapshot.id,
          remoteID: snapshot.remoteID,
          title: snapshot.title,
          artist: snapshot.artist,
          album: snapshot.album,
          duration: snapshot.duration,
          artwork: snapshot.artwork,
          artworkURL: snapshot.artworkURL,
          fileUrl: snapshot.fileUrl,
          seconds: 0,
          plays: 0,
          days: days.map((item) => ({ key: item.key, date: item.date, seconds: 0, plays: 0 })),
        });
      }
      const series = songSeries.get(songKey);
      const seriesDay = series.days[dayIndexByKey.get(key)];
      series.seconds += seconds;
      if (qualifiesAsPlay) series.plays += 1;
      seriesDay.seconds += seconds;
      if (qualifiesAsPlay) seriesDay.plays += 1;
    }
  }
  return {
    granularity: hourly ? "hour" : "day",
    days,
    totalSeconds: days.reduce((total, day) => total + day.seconds, 0),
    plays: days.reduce((total, day) => total + day.plays, 0),
    todaySeconds,
    todayPlays,
    songs: songKeys.size,
    songSeries: [...songSeries.values()].sort((left, right) => right.seconds - left.seconds || right.plays - left.plays),
  };
}

export function summarizeListeningStats(state, now = new Date()) {
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
    const qualifiesAsPlay = listeningHistoryEntryQualifiesAsPlay(state, entry);
    totalSeconds += seconds;
    if (qualifiesAsPlay) plays += 1;
    if (localDayKey(timestamp) === todayKey) todaySeconds += seconds;
    if (!entry.trackID) continue;

    const songKey = listeningHistorySongKey(entry);
    const snapshot = listeningHistoryTrackSnapshot(state, entry);
    const song = songs.get(songKey) || {
      trackID: snapshot.id,
      remoteID: snapshot.remoteID,
      title: snapshot.title,
      artist: snapshot.artist,
      album: snapshot.album,
      duration: snapshot.duration,
      artwork: snapshot.artwork,
      artworkURL: snapshot.artworkURL,
      fileUrl: snapshot.fileUrl,
      seconds: 0,
      plays: 0,
    };
    song.seconds += seconds;
    if (qualifiesAsPlay) song.plays += 1;
    songs.set(songKey, song);

    const artist = snapshot.artist;
    const artistStats = artists.get(artist) || { artist, seconds: 0, plays: 0 };
    artistStats.seconds += seconds;
    if (qualifiesAsPlay) artistStats.plays += 1;
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

export function mergeListeningHistoryDocument(
  state,
  document,
  requestedProfileID = state?.syncProfileID || "default",
  requestedServerURL = state?.serverURL,
  catalog = [],
) {
  const profileID = typeof document?.profile_id === "string" && document.profile_id
    ? document.profile_id
    : typeof document?.profileID === "string" && document.profileID
      ? document.profileID
      : requestedProfileID;
  const requestedServerOrigin = normalizedServerOrigin(requestedServerURL);
  const documentServerOrigin = normalizedServerOrigin(document?.server_origin ?? document?.serverOrigin);
  if (
    profileID !== requestedProfileID
    || !requestedServerOrigin
    || (documentServerOrigin && documentServerOrigin !== requestedServerOrigin)
    || !Array.isArray(document?.entries)
  ) return false;

  const historyIdentity = (entry) => `${normalizedServerOrigin(entry?.serverOrigin) || "unowned"}#${entry?.profileID || "default"}#${entry?.id || ""}`;
  const entriesByID = new Map((state.listeningHistory || []).map((entry) => [historyIdentity(entry), entry]));
  const activeTracks = tracksForActiveProfile(state);
  const tracksByID = new Map(activeTracks.map((track) => [track.id, track]));
  const tracksByRemoteID = new Map(activeTracks
    .filter((track) => track?.remoteID && (track.syncProfileID || "default") === profileID)
    .map((track) => [track.remoteID, track]));
  const songsByRemoteID = new Map((Array.isArray(catalog) ? catalog : [])
    .filter((song) => optionalHistoryText(song?.id, 128))
    .map((song) => [String(song.id), song]));
  for (const remote of document.entries) {
    const id = optionalHistoryText(remote?.id, 128);
    const rawTrackID = optionalHistoryText(remote?.track_id ?? remote?.trackID, 128);
    const startedAt = new Date(remote?.started_at ?? remote?.startedAt);
    if (!id || !rawTrackID || !Number.isFinite(startedAt.getTime())) continue;
    const identity = `${requestedServerOrigin}#${profileID}#${id}`;
    const existing = entriesByID.get(identity);
    const remoteID = optionalHistoryText(remote?.song_id ?? remote?.remoteID, 128)
      || existing?.remoteID;
    const mappedTrack = (remoteID && tracksByRemoteID.get(remoteID)) || tracksByID.get(rawTrackID);
    const catalogSong = remoteID ? songsByRemoteID.get(remoteID) : null;
    const remoteDuration = normalizedHistoryDuration(remote?.duration_seconds ?? remote?.duration);
    const catalogDuration = normalizedHistoryDuration(catalogSong?.duration_seconds ?? catalogSong?.duration);
    entriesByID.set(identity, {
      id,
      trackID: mappedTrack?.id || existing?.trackID || rawTrackID,
      profileID,
      serverOrigin: requestedServerOrigin,
      startedAt: existing?.startedAt || startedAt.toISOString(),
      listenedSeconds: Math.max(existing?.listenedSeconds || 0, Number(remote?.listened_seconds ?? remote?.listenedSeconds) || 0),
      remoteID: remoteID || mappedTrack?.remoteID || null,
      title: preferredListeningHistoryMetadata(
        "title", remote?.title, catalogSong?.title, catalogSong?.name, catalogSong?.filename, existing?.title, mappedTrack?.title,
      ),
      artist: preferredListeningHistoryMetadata(
        "artist", remote?.artist, catalogSong?.artist, existing?.artist, mappedTrack?.artist,
      ),
      album: preferredListeningHistoryMetadata(
        "album", remote?.album, catalogSong?.album, existing?.album, mappedTrack?.album,
      ),
      duration: (remoteDuration > 0 ? remoteDuration : null)
        ?? (catalogDuration > 0 ? catalogDuration : null)
        ?? (existing?.duration > 0 ? existing.duration : null)
        ?? normalizedHistoryDuration(mappedTrack?.duration),
      artworkURL: listeningHistoryArtworkURL(
        remote?.artwork_url ?? remote?.artworkURL
          ?? catalogSong?.artwork_url ?? catalogSong?.artworkURL
          ?? existing?.artworkURL ?? mappedTrack?.artworkURL,
        requestedServerOrigin,
      ),
      originatedOnThisDevice: existing?.originatedOnThisDevice ?? false,
    });
  }
  state.listeningHistory = [...entriesByID.values()]
    .sort((left, right) => Date.parse(left.startedAt) - Date.parse(right.startedAt))
    .slice(-2000);
  return true;
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

export function playbackGainForVolume(sliderValue) {
  const normalized = normalizedVolume(sliderValue, 0);
  return normalized * normalized;
}

export function filterTracks(tracks, query, mode = "all") {
  const value = String(query || "").trim().toLocaleLowerCase();
  let filtered = value
    ? tracks.filter((track) => [track.title, track.artist, track.album, track.filePath].some((field) => String(field || "").toLocaleLowerCase().includes(value)))
    : [...tracks];
  if (mode === "audio") {
    filtered = filtered.filter((track) => /\.(aac|aif|aiff|alac|flac|m4a|m4b|mp3|ogg|opus|wav)$/i.test(String(track.filePath || "")));
  } else if (mode === "video") {
    filtered = filtered.filter(isInstalledVideoTrack);
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

export function shuffledTrackIDs(tracks, currentID = null, random = Math.random) {
  const ids = unique((Array.isArray(tracks) ? tracks : []).map((track) => track?.id).filter(Boolean));
  if (!ids.length) return [];
  const currentIndex = ids.indexOf(currentID);
  const remaining = currentIndex >= 0 ? ids.filter((id) => id !== currentID) : [...ids];
  for (let index = remaining.length - 1; index > 0; index -= 1) {
    const randomValue = Math.max(0, Math.min(0.999999999999, Number(random()) || 0));
    const otherIndex = Math.floor(randomValue * (index + 1));
    [remaining[index], remaining[otherIndex]] = [remaining[otherIndex], remaining[index]];
  }
  return currentIndex >= 0 ? [currentID, ...remaining] : remaining;
}

export function nextIndex(tracks, currentID, direction = 1) {
  if (!tracks.length) return -1;
  const current = tracks.findIndex((track) => track.id === currentID);
  if (current < 0) return direction >= 0 ? 0 : tracks.length - 1;
  return (current + (direction >= 0 ? 1 : -1) + tracks.length) % tracks.length;
}

export function tracksForPlaylist(state, playlistID, catalog = []) {
  const playlist = state.playlists.find((item) => item.id === playlistID);
  if (!playlist) return [];
  const localTracks = playlist.trackIDs.map((id) => state.tracks.find((track) => track.id === id)).filter(Boolean);
  if (playlist.isSystem || !Array.isArray(playlist.remoteSongIDs)) return localTracks;

  const orderedRemoteIDs = unique(playlist.remoteSongIDs.map((id) => String(id || "").trim()).filter(Boolean));
  const remoteIDSet = new Set(orderedRemoteIDs);
  const downloadedByRemoteID = new Map();
  const fallbackPreviousKeys = localTracks.map((track) => {
    const remoteID = String(track?.remoteID || "").trim();
    if (!remoteID || !remoteIDSet.has(remoteID) || !trackBelongsToActiveProfile(state, track)) {
      return playlistLocalEntryKey(track.id);
    }
    if (!downloadedByRemoteID.has(remoteID)) downloadedByRemoteID.set(remoteID, track);
    return playlistRemoteEntryKey(remoteID);
  });
  const orderedKeys = orderedRemoteIDs.map(playlistRemoteEntryKey);
  const validLocalKeys = new Set(fallbackPreviousKeys.filter((key) => key.startsWith("local:")));
  const validRemoteKeys = new Set(orderedKeys);
  const storedPreviousKeys = normalizedPlaylistEntryOrder(playlist.entryOrder).filter((key) =>
    key.startsWith("local:") ? validLocalKeys.has(key) : validRemoteKeys.has(key));
  const previousKeys = unique([...storedPreviousKeys, ...fallbackPreviousKeys]);
  const preservedKeys = previousKeys.filter((key) => key.startsWith("local:"));
  const catalogByID = new Map((Array.isArray(catalog) ? catalog : [])
    .filter((song) => song?.id)
    .map((song) => [String(song.id), song]));

  return mergePlaylistOrderWithPreservedItems(previousKeys, orderedKeys, preservedKeys).map((key) => {
    if (key.startsWith("local:")) {
      return state.tracks.find((track) => track.id === key.slice("local:".length));
    }
    const remoteID = key.slice("remote:".length);
    const downloaded = downloadedByRemoteID.get(remoteID);
    if (downloaded) return downloaded;
    const song = catalogByID.get(remoteID);
    return {
      id: `playlist-remote:${remoteID}`,
      remoteID,
      title: song?.title || song?.name || song?.filename || "Unavailable song",
      artist: song?.artist || "Not downloaded on this device",
      album: song?.album || "Server playlist",
      duration: Number(song?.duration_seconds ?? song?.duration) || 0,
      artwork: song?.artwork || null,
      filePath: song?.filename || "",
      sourceServer: state.serverURL,
      syncProfileID: state.syncProfileID || "default",
      available: false,
      missing: false,
      playlistUnavailable: true,
    };
  }).filter(Boolean);
}

function playlistLocalEntryKey(trackID) {
  const id = String(trackID || "").trim();
  return id ? `local:${id}` : "";
}

function playlistRemoteEntryKey(remoteID) {
  const id = String(remoteID || "").trim();
  return id ? `remote:${id}` : "";
}

export function normalizedPlaylistEntryOrder(value) {
  return unique((Array.isArray(value) ? value : [])
    .map((key) => String(key || "").trim())
    .filter((key) => (key.startsWith("local:") && key.length > "local:".length)
      || (key.startsWith("remote:") && key.length > "remote:".length)));
}

export function playlistEntryKey(playlist, track) {
  const remoteID = String(track?.remoteID || "").trim();
  if (remoteID && Array.isArray(playlist?.remoteSongIDs) && playlist.remoteSongIDs.includes(remoteID)) {
    return playlistRemoteEntryKey(remoteID);
  }
  return playlistLocalEntryKey(track?.id);
}

export function removeLibraryTracksFromPlaylists(
  state,
  trackIDs,
  catalog = [],
  { catalogIsAuthoritative = false } = {},
) {
  const requestedIDs = new Set(Array.isArray(trackIDs)
    ? trackIDs
    : trackIDs instanceof Set ? [...trackIDs] : []);
  const removedTracks = (Array.isArray(state?.tracks) ? state.tracks : [])
    .filter((track) => requestedIDs.has(track?.id));
  const catalogIDs = new Set((Array.isArray(catalog) ? catalog : [])
    .map((song) => String(song?.id || "").trim())
    .filter(Boolean));
  const affectedPlaylistIDs = [];
  const remoteMembershipChangedPlaylistIDs = [];
  const preservedRemoteSongIDs = new Set();

  for (const playlist of Array.isArray(state?.playlists) ? state.playlists : []) {
    const affectedTracks = removedTracks.filter((track) =>
      Array.isArray(playlist.trackIDs) && playlist.trackIDs.includes(track.id));
    if (!affectedTracks.length) continue;
    affectedPlaylistIDs.push(playlist.id);
    if (playlist.isSystem) {
      playlist.trackIDs = playlist.trackIDs.filter((id) => !requestedIDs.has(id));
      continue;
    }

    const previousRemoteSongIDs = unique((Array.isArray(playlist.remoteSongIDs) ? playlist.remoteSongIDs : [])
      .map((id) => String(id || "").trim())
      .filter(Boolean));
    let nextRemoteSongIDs = [...previousRemoteSongIDs];
    let entryKeys = Array.isArray(playlist.entryOrder)
      ? normalizedPlaylistEntryOrder(playlist.entryOrder)
      : tracksForPlaylist(state, playlist.id, catalog)
        .map((entry) => playlistEntryKey(playlist, entry))
        .filter(Boolean);
    playlist.trackIDs = playlist.trackIDs.filter((id) => !requestedIDs.has(id));
    for (const track of affectedTracks) {
      const localKey = playlistLocalEntryKey(track.id);
      const remoteID = String(track.remoteID || "").trim();
      const remoteKey = playlistRemoteEntryKey(remoteID);
      const isActiveRemote = Boolean(remoteID && trackBelongsToActiveProfile(state, track));
      const hasCanonicalMembership = Boolean(remoteID && nextRemoteSongIDs.includes(remoteID));
      const catalogConfirmsMembership = Boolean(
        isActiveRemote && catalogIsAuthoritative && catalogIDs.has(remoteID),
      );
      const isConclusivelyMissing = isActiveRemote
        && catalogIsAuthoritative
        && !catalogIDs.has(remoteID);
      if (isActiveRemote && hasCanonicalMembership && !isConclusivelyMissing) {
        preservedRemoteSongIDs.add(remoteID);
        entryKeys = entryKeys.map((key) => key === localKey ? remoteKey : key);
      } else if (!hasCanonicalMembership && catalogConfirmsMembership) {
        preservedRemoteSongIDs.add(remoteID);
        entryKeys = entryKeys.map((key) => key === localKey ? remoteKey : key);
        nextRemoteSongIDs.push(remoteID);
      } else {
        entryKeys = entryKeys.filter((key) => key !== localKey && (!isConclusivelyMissing || key !== remoteKey));
        if (isConclusivelyMissing) {
          nextRemoteSongIDs = nextRemoteSongIDs.filter((id) => id !== remoteID);
        }
      }
    }
    entryKeys = normalizedPlaylistEntryOrder(entryKeys);
    playlist.remoteSongIDs = nextRemoteSongIDs;
    playlist.entryOrder = entryKeys;
    if (playlist.remoteSongIDs.length !== previousRemoteSongIDs.length
        || playlist.remoteSongIDs.some((id, index) => id !== previousRemoteSongIDs[index])) {
      remoteMembershipChangedPlaylistIDs.push(playlist.id);
    }
  }

  return {
    affectedPlaylistIDs,
    remoteMembershipChangedPlaylistIDs,
    preservedRemoteSongIDs: [...preservedRemoteSongIDs],
  };
}

export function reorderPlaylistEntries(state, playlist, sourceKey, targetKey, insertAfter = false) {
  if (!playlist || playlist.isSystem) return false;
  const presented = tracksForPlaylist(state, playlist.id);
  const currentOrder = presented.map((track) => playlistEntryKey(playlist, track)).filter(Boolean);
  const reordered = reorderPlaylistTrackIDs(currentOrder, sourceKey, targetKey, insertAfter);
  if (reordered.length !== currentOrder.length
      || reordered.every((key, index) => key === currentOrder[index])) return false;

  const localTrackIDs = new Map();
  const downloadedTrackIDs = new Map();
  for (const track of state.tracks || []) {
    const localKey = playlistLocalEntryKey(track?.id);
    if (localKey) localTrackIDs.set(localKey, track.id);
    const remoteID = String(track?.remoteID || "").trim();
    if (remoteID && trackBelongsToActiveProfile(state, track) && !downloadedTrackIDs.has(remoteID)) {
      downloadedTrackIDs.set(remoteID, track.id);
    }
  }

  playlist.entryOrder = reordered;
  playlist.trackIDs = reordered.flatMap((key) => {
    if (key.startsWith("local:")) {
      const trackID = localTrackIDs.get(key);
      return trackID ? [trackID] : [];
    }
    const trackID = downloadedTrackIDs.get(key.slice("remote:".length));
    return trackID ? [trackID] : [];
  });
  playlist.remoteSongIDs = reordered
    .filter((key) => key.startsWith("remote:"))
    .map((key) => key.slice("remote:".length));
  return true;
}

export function reorderPlaylistTrackIDs(trackIDs, sourceID, targetID, insertAfter = false) {
  const reordered = Array.isArray(trackIDs) ? [...trackIDs] : [];
  const sourceIndex = reordered.indexOf(sourceID);
  if (sourceIndex < 0 || sourceID === targetID || !reordered.includes(targetID)) return reordered;
  reordered.splice(sourceIndex, 1);
  const targetIndex = reordered.indexOf(targetID);
  reordered.splice(targetIndex + (insertAfter ? 1 : 0), 0, sourceID);
  return reordered;
}

export function playlistInsertionIndex(rowMidpoints, pointerY) {
  if (!Array.isArray(rowMidpoints) || !rowMidpoints.length
    || !rowMidpoints.every(Number.isFinite) || !Number.isFinite(pointerY)) return -1;
  const index = rowMidpoints.findIndex((midpoint) => pointerY < midpoint);
  return index < 0 ? rowMidpoints.length : index;
}

export function mergePlaylistOrderWithPreservedItems(previousIDs, orderedIDs, preservedIDs) {
  const previous = unique(Array.isArray(previousIDs) ? previousIDs : []);
  const ordered = unique(Array.isArray(orderedIDs) ? orderedIDs : []);
  const orderedSet = new Set(ordered);
  const preserved = new Set(unique(Array.isArray(preservedIDs) ? preservedIDs : [])
    .filter((id) => previous.includes(id) && !orderedSet.has(id)));
  const merged = [];
  let orderedIndex = 0;

  for (const previousID of previous) {
    if (preserved.has(previousID)) {
      merged.push(previousID);
    } else if (orderedIndex < ordered.length) {
      merged.push(ordered[orderedIndex]);
      orderedIndex += 1;
    }
  }
  merged.push(...ordered.slice(orderedIndex));
  return unique(merged);
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
  const associationConflict = remoteAssociationConflictMessage(target, {
    serverURL: sourceServer,
    profileID,
  });
  if (associationConflict) throw new Error(associationConflict);
  const previousRemoteID = String(target.remoteID || "").trim() || null;
  const duplicateIDs = new Set(state.tracks
    .filter((track) =>
      track?.id !== target.id
      && track?.remoteID === remoteID
      && (track.syncProfileID || "default") === profileID
      && Boolean(sourceServer && normalizedServerOrigin(track.sourceServer) === sourceServer))
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
    const affected = (playlist.trackIDs || []).some((id) => id === target.id || duplicateIDs.has(id))
      || Boolean(previousRemoteID && (playlist.remoteSongIDs || []).includes(previousRemoteID));
    playlist.trackIDs = remap(playlist.trackIDs);
    if (!affected || playlist.isSystem) continue;
    if (previousRemoteID && previousRemoteID !== remoteID) {
      playlist.remoteSongIDs = unique((playlist.remoteSongIDs || [])
        .map((id) => id === previousRemoteID ? remoteID : id));
    }
    updatePlaylistRemoteSongIDs(state, playlist);
    const id = normalizedPlaylistID(playlist.id);
    state.deletedPlaylistIDs = state.deletedPlaylistIDs.filter((value) => normalizedPlaylistID(value) !== id);
    state.dirtyPlaylistIDs = unique([...state.dirtyPlaylistIDs.map(normalizedPlaylistID), id]);
  }

  state.playbackQueueIDs = remap(state.playbackQueueIDs);
  state.playbackSourceQueueIDs = remap(state.playbackSourceQueueIDs);
  if (duplicateIDs.has(state.currentTrackID)) state.currentTrackID = target.id;
  state.listeningHistory = (state.listeningHistory || []).map((entry) =>
    duplicateIDs.has(entry.trackID) ? { ...entry, trackID: target.id } : entry);
  state.tracks = state.tracks.filter((track) => !duplicateIDs.has(track.id));

  if (wasFavorite) {
    state.remoteLikedSongIDs = unique([
      ...state.remoteLikedSongIDs.filter((id) => id !== previousRemoteID),
      remoteID,
    ]);
    state.dirtyRemoteLikeSongIDs = unique([
      ...state.dirtyRemoteLikeSongIDs,
      ...(previousRemoteID && previousRemoteID !== remoteID ? [previousRemoteID] : []),
      remoteID,
    ]);
    state.likesDirty = true;
  }
  const previousClipKey = previousRemoteID ? `remote:${previousRemoteID}` : localClipKey;
  const previousClipRange = state.clipRanges?.[previousClipKey] || localClipRange;
  const remoteClipKey = `remote:${remoteID}`;
  if (previousClipRange && previousClipKey !== remoteClipKey) {
    state.clipRanges[remoteClipKey] = previousClipRange;
    delete state.clipRanges[previousClipKey];
    state.dirtyClipRangeKeys = unique([
      ...state.dirtyClipRangeKeys,
      ...(previousRemoteID ? [previousClipKey] : []),
      remoteClipKey,
    ]);
    state.deletedClipRangeKeys = unique([
      ...state.deletedClipRangeKeys.filter((key) => key !== remoteClipKey),
      ...(previousRemoteID ? [previousClipKey] : []),
    ]);
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
    if (!serverTrack?.remoteID || !trackBelongsToActiveProfile(state, serverTrack) || !hash || !Number.isFinite(size) || size <= 0) continue;
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

export function serverUploadConfigurationError({ serverURL, adminToken } = {}) {
  let parsedServerURL = null;
  try { parsedServerURL = new URL(String(serverURL || "").trim()); } catch { /* Report the shared URL error below. */ }
  if (!parsedServerURL || !["http:", "https:"].includes(parsedServerURL.protocol)) {
    return "Add a complete http:// or https:// server URL before uploading.";
  }
  if (parsedServerURL.username || parsedServerURL.password) {
    return "Remove credentials from the server URL before uploading.";
  }
  const loopbackHosts = new Set(["localhost", "127.0.0.1", "[::1]"]);
  const hostname = parsedServerURL.hostname.toLocaleLowerCase().replace(/\.$/, "");
  if (parsedServerURL.protocol !== "https:" && !loopbackHosts.has(hostname)) {
    return "Use an HTTPS server URL before authenticating. HTTP is only available for explicit loopback development.";
  }
  if (!String(adminToken || "").trim()) return "Sign in to your Resonance account before uploading.";
  return null;
}

export function serverUploadBlockedByActivity({ uploadInFlight = false, transferActive = false } = {}) {
  return Boolean(uploadInFlight || transferActive);
}

export function localImportNeedsServerContext({ serverBacked = false, uploadRequested = false } = {}) {
  return Boolean(serverBacked || uploadRequested);
}

export function localImportCandidateCanAutoSelect(candidate) {
  if (!candidate || typeof candidate !== "object") return false;
  return candidate.autoSelectable !== false
    && candidate.auto_selectable !== false
    && candidate.requiresReview !== true
    && candidate.requires_review !== true
    && candidate.actionable !== false;
}

function localImportPlaylistCandidateIdentity(candidate) {
  if (!candidate || typeof candidate !== "object") return null;
  const importMetadata = candidate.importMetadata && typeof candidate.importMetadata === "object"
    ? candidate.importMetadata
    : null;
  const metadataProvider = String(importMetadata?.provider || importMetadata?.searchProvider || "")
    .trim()
    .toLocaleLowerCase();
  if (metadataProvider && !metadataProvider.includes("youtube")) {
    const metadataID = [
      importMetadata.trackID,
      importMetadata.providerID,
      importMetadata.providerId,
      importMetadata.sourcePageURL,
      importMetadata.sourceURL,
    ].find((value) => typeof value === "string" && value.trim());
    if (metadataID) return { provider: metadataProvider, id: metadataID.trim() };
  }
  const providerID = [candidate.videoID, candidate.providerID, candidate.candidateID, candidate.trackID]
    .find((value) => typeof value === "string" && value.trim());
  if (providerID) {
    const normalizedID = providerID.trim();
    if (normalizedID.toLocaleLowerCase().startsWith("soundcloud:")) {
      return { provider: "soundcloud", id: normalizedID };
    }
    const declaredProvider = String(candidate.sourceProvider || candidate.searchProvider || candidate.provider || "")
      .trim()
      .toLocaleLowerCase();
    const provider = /^[A-Za-z0-9_-]{11}$/.test(normalizedID) || declaredProvider.includes("youtube")
      ? "youtube"
      : declaredProvider || "source";
    return { provider, id: normalizedID };
  }
  const sourcePageURL = canonicalYouTubeSourcePageURL(candidate.sourceURL, candidate.sourcePageURL);
  return sourcePageURL ? { provider: "youtube", id: sourcePageURL } : null;
}

export function localImportPlaylistTransferKey(candidate, mediaKind = "audio") {
  const identity = localImportPlaylistCandidateIdentity(candidate);
  if (!identity) return null;
  const kind = mediaKind === "video" ? "video" : "audio";
  return `${kind}:${identity.provider}:${identity.id}`;
}

// Playlist rows remain independently selectable, but one provider track should
// only occupy one transfer slot. This keeps repeated rows visible to the user
// while preventing duplicate downloads and retries (including failed transfers).
export function uniqueLocalImportPlaylistCandidates(candidates, mediaKind = "audio") {
  if (!Array.isArray(candidates)) return [];
  const seen = new Set();
  return candidates.filter((candidate) => {
    const key = localImportPlaylistTransferKey(candidate, mediaKind);
    if (!key) return true;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

export function buildLocalImportSourceIdentity(candidate, metadata = {}) {
  if (candidate?.sourceIdentity && typeof candidate.sourceIdentity === "object") return candidate.sourceIdentity;
  const match = candidate?.match && typeof candidate.match === "object" ? candidate.match : {};
  const mediaProvider = candidate?.sourceProvider || candidate?.searchProvider || "unknown";
  const mediaProviderID = candidate?.providerID || candidate?.candidateID || candidate?.videoID || candidate?.trackID || candidate?.fileID || null;
  const mediaPageURL = candidate?.sourcePageURL || candidate?.sourceURL || null;
  const metadataProvider = metadata?.provider || (metadata?.trackID ? candidate?.searchProvider : null) || mediaProvider;
  const metadataProviderID = metadata?.providerID || metadata?.providerId || metadata?.trackID
    || (metadataProvider === mediaProvider ? mediaProviderID : null);
  const metadataPageURL = metadata?.sourcePageURL || metadata?.sourceURL
    || (metadataProvider === mediaProvider ? mediaPageURL : null);
  const evidence = {
    evidenceStrength: candidate?.evidenceStrength || candidate?.evidence_strength || null,
    requiresReview: candidate?.requiresReview === true || candidate?.requires_review === true,
    actionable: candidate?.actionable !== false,
    sourceKind: candidate?.sourceKind || null,
    searchProvider: candidate?.searchProvider || null,
    matchedMediaProvider: mediaProvider,
    matchedMediaProviderID: mediaProviderID,
    matchedMediaReference: candidate?.mediaSourceURL || candidate?.sourceURL || null,
    titleScore: Number.isFinite(Number(match.title)) ? Number(match.title) : null,
    artistScore: Number.isFinite(Number(match.artist)) ? Number(match.artist) : null,
    albumScore: Number.isFinite(Number(match.album)) ? Number(match.album) : null,
    durationScore: Number.isFinite(Number(match.duration)) ? Number(match.duration) : null,
    durationDeltaSeconds: Number.isFinite(Number(match.durationDeltaSeconds)) ? Number(match.durationDeltaSeconds) : null,
  };
  const identity = {
    provider: metadataProvider,
    providerID: metadataProviderID,
    sourcePageURL: metadataPageURL,
    confidence: candidate?.confidence || null,
    score: Number.isFinite(Number(candidate?.score)) ? Number(candidate.score) : null,
    evidence,
  };
  const sameIdentity = metadataProvider === mediaProvider
    && String(metadataProviderID || "") === String(mediaProviderID || "")
    && String(metadataPageURL || "") === String(mediaPageURL || "");
  if (sameIdentity) {
    identity.mediaSourceURL = candidate?.mediaSourceURL || candidate?.sourceURL || null;
    return identity;
  }
  identity.aliases = [{
    provider: mediaProvider,
    providerID: mediaProviderID,
    sourcePageURL: mediaPageURL,
    mediaSourceURL: candidate?.mediaSourceURL || candidate?.sourceURL || null,
    confidence: candidate?.confidence || null,
    score: Number.isFinite(Number(candidate?.score)) ? Number(candidate.score) : null,
    evidence: { ...evidence, identityRole: "matched_media" },
  }];
  return identity;
}

export function mergeTrackSourceIdentity(track, sourceIdentity) {
  if (!track || !sourceIdentity || typeof sourceIdentity !== "object") return false;
  const existingCandidates = [
    ...(Array.isArray(track.sourceIdentities) ? track.sourceIdentities : []),
    ...(track.sourceIdentity ? [track.sourceIdentity, ...(track.sourceIdentity.aliases || [])] : []),
  ].filter((identity) => identity && typeof identity === "object");
  const incomingCandidates = [
    sourceIdentity,
    ...(Array.isArray(sourceIdentity.aliases) ? sourceIdentity.aliases : []),
  ].filter((identity) => identity && typeof identity === "object");
  const identityKey = (identity) => JSON.stringify([
    identity.provider || null,
    identity.providerID || identity.providerId || null,
    identity.sourcePageURL || identity.sourceURL || null,
    identity.mediaSourceURL || null,
  ]);
  const identityPayload = (identity) => {
    const { aliases: _aliases, ...payload } = identity;
    return payload;
  };
  const mergeIdentityValues = (current, incoming) => {
    const merged = current ? { ...identityPayload(current) } : {};
    for (const [key, value] of Object.entries(identityPayload(incoming))) {
      if (value === null || value === undefined || value === "") continue;
      if (key === "evidence" && value && typeof value === "object" && !Array.isArray(value)) {
        const priorEvidence = merged.evidence && typeof merged.evidence === "object" && !Array.isArray(merged.evidence)
          ? merged.evidence
          : {};
        merged.evidence = { ...priorEvidence };
        for (const [evidenceKey, evidenceValue] of Object.entries(value)) {
          if (evidenceValue !== null && evidenceValue !== undefined && evidenceValue !== "") {
            merged.evidence[evidenceKey] = evidenceValue;
          }
        }
      } else {
        merged[key] = value;
      }
    }
    return merged;
  };
  const collectIdentities = (candidates) => {
    const keys = [];
    const identitiesByKey = new Map();
    for (const identity of candidates) {
      const key = identityKey(identity);
      if (!identitiesByKey.has(key)) keys.push(key);
      identitiesByKey.set(key, mergeIdentityValues(identitiesByKey.get(key), identity));
    }
    return { keys: keys.slice(0, 8), identitiesByKey };
  };
  const previous = collectIdentities(existingCandidates);
  const next = collectIdentities([...existingCandidates, ...incomingCandidates]);
  const previousIdentities = previous.keys.map((key) => previous.identitiesByKey.get(key));
  const identities = next.keys.map((key) => next.identitiesByKey.get(key));
  const changed = JSON.stringify(previousIdentities) !== JSON.stringify(identities);
  if (!changed) return false;
  const canonical = track.sourceIdentity || sourceIdentity;
  const canonicalKey = identityKey(canonical);
  track.sourceIdentity = {
    ...(next.identitiesByKey.get(canonicalKey) || identityPayload(canonical)),
    aliases: identities.filter((identity) => identityKey(identity) !== canonicalKey),
  };
  track.sourceIdentities = identities;
  track.sourceURL = track.sourceIdentity.sourcePageURL || track.sourceURL || null;
  return true;
}

export function catalogRequestCanApply({ requestGeneration, currentGeneration, contextCurrent = true } = {}) {
  return Boolean(contextCurrent) && requestGeneration === currentGeneration;
}

export function serverCatalogAuthoritySnapshot(context = {}, catalogGeneration = 0) {
  return {
    profileGeneration: Number(context.generation) || 0,
    profileID: String(context.profileID || "default"),
    serverKey: String(context.serverKey || ""),
    token: String(context.token || ""),
    catalogGeneration: Number(catalogGeneration) || 0,
  };
}

export function serverCatalogAuthorityIsCurrent(authority, context = {}, catalogGeneration = 0) {
  if (!authority) return false;
  const current = serverCatalogAuthoritySnapshot(context, catalogGeneration);
  return authority.profileGeneration === current.profileGeneration
    && authority.profileID === current.profileID
    && authority.serverKey === current.serverKey
    && authority.token === current.token
    && authority.catalogGeneration === current.catalogGeneration;
}

export function serverTrackRemoteIDBelongsToContext(track, { serverURL, profileID = "default" } = {}) {
  if (!String(track?.remoteID || "").trim()) return false;
  const sourceServer = normalizedServerOrigin(track?.sourceServer);
  const activeServer = normalizedServerOrigin(serverURL);
  return Boolean(sourceServer && activeServer && sourceServer === activeServer)
    && String(track?.syncProfileID || "default") === String(profileID || "default");
}

export function remoteAssociationConflictMessage(track, { serverURL, profileID = "default" } = {}) {
  const remoteID = String(track?.remoteID || "").trim();
  const rawSourceServer = String(track?.sourceServer || "").trim();
  const rawProfileID = String(track?.syncProfileID || "").trim();
  if (!remoteID && !rawSourceServer && !rawProfileID) return null;
  const sourceServer = normalizedServerOrigin(rawSourceServer);
  const activeServer = normalizedServerOrigin(serverURL);
  const storedProfileID = rawProfileID || "default";
  const targetProfileID = String(profileID || "default");
  if (sourceServer && activeServer && sourceServer === activeServer && storedProfileID === targetProfileID) return null;
  return "This song is already linked to a different server or profile. Switch back to its original server and profile; Resonance left the existing link unchanged.";
}

export function remoteAssociationConflictFilePaths(tracks, context = {}) {
  return unique((Array.isArray(tracks) ? tracks : []).flatMap((track) => {
    const filePath = String(track?.filePath || "").trim();
    return filePath && remoteAssociationConflictMessage(track, context) ? [filePath] : [];
  }));
}

export function preservedUploadSourceURL(track) {
  const candidates = [
    track?.sourceIdentity?.sourcePageURL,
    track?.sourceURL,
    track?.downloadSourceURL,
    track?.sourceIdentity?.mediaSourceURL,
  ];
  for (const value of candidates) {
    const source = typeof value === "string" ? value.trim() : "";
    if (!source || source.length > 8_192) continue;
    try {
      const url = new URL(source);
      if (url.protocol === "https:" && !url.username && !url.password && !url.hash) return url.href;
    } catch { /* Try the next preserved source candidate. */ }
  }
  return null;
}

export function mergeUploadedSongsIntoCatalog(catalog, results) {
  const merged = Array.isArray(catalog) ? [...catalog] : [];
  for (const result of Array.isArray(results) ? results : []) {
    const remoteSong = result?.remoteSong;
    const remoteID = String(remoteSong?.id || "").trim();
    if (!remoteID) continue;
    const index = merged.findIndex((song) => String(song?.id || "").trim() === remoteID);
    if (index >= 0) merged[index] = { ...merged[index], ...remoteSong };
    else merged.push(remoteSong);
  }
  return merged;
}

export function planMissingDownloadedUploads(state, catalog) {
  const songs = Array.isArray(catalog) ? catalog : [];
  const remoteIDs = new Set(songs.map((song) => String(song?.id || "").trim()).filter(Boolean));
  const validSHA256 = (value) => /^[a-f\d]{64}$/i.test(String(value || "").trim());
  const remoteByHash = new Map(songs.map((song) => {
    const hash = String(song?.content_sha256 || song?.contentSha256 || "").trim().toLocaleLowerCase();
    return [hash, song];
  }).filter(([hash]) => validSHA256(hash)));
  const uploadTracks = [];
  const alreadyPresent = [];
  const matches = [];
  const ambiguous = [];
  const missingSource = [];
  const activeServer = normalizedServerOrigin(state?.serverURL);
  const activeProfileID = String(state?.syncProfileID || "default");

  for (const track of state.tracks || []) {
    if (!track?.filePath || track.available === false) continue;
    const sourceURL = preservedUploadSourceURL(track);
    const sourceServer = normalizedServerOrigin(track.sourceServer);
    const profileID = String(track.syncProfileID || "default");
    const hasRemoteAssociation = Boolean(String(track.remoteID || "").trim() || String(track.sourceServer || "").trim());
    if (hasRemoteAssociation && (!activeServer || sourceServer !== activeServer || profileID !== activeProfileID)) continue;
    if (!hasRemoteAssociation && !sourceURL) continue;
    if (track.remoteID && remoteIDs.has(String(track.remoteID))) {
      alreadyPresent.push(track);
      continue;
    }
    const hash = String(track.contentSha256 || "").trim().toLocaleLowerCase();
    const exactMatch = validSHA256(hash) ? remoteByHash.get(hash) : null;
    if (exactMatch) {
      matches.push({ trackID: track.id, remoteSong: exactMatch });
      continue;
    }
    const metadataMatches = songs.filter((song) => serverSongMetadataMatches(track, song));
    if (metadataMatches.length) {
      ambiguous.push({ track, candidates: metadataMatches });
      continue;
    }
    if (!sourceURL) {
      missingSource.push(track);
      continue;
    }
    uploadTracks.push(track);
  }
  return { uploadTracks, alreadyPresent, matches, ambiguous, missingSource };
}

export function formatServerUploadFailureNotice(failures) {
  const items = (Array.isArray(failures) ? failures : []).map((failure) => {
    const title = String(failure?.title || failure?.filename || "Unknown song").trim();
    const artist = String(failure?.artist || "").trim();
    return artist ? `“${title}” — ${artist}` : `“${title}”`;
  });
  if (!items.length) return "";
  return `${items.length} song${items.length === 1 ? "" : "s"} failed to upload after retrying: ${items.join("; ")}.`;
}

export function updatePlaylistRemoteSongIDs(state, playlist) {
  const unresolved = (playlist.remoteSongIDs || []).filter((remoteID) =>
    !state.tracks.some((track) => track.remoteID === remoteID && trackBelongsToActiveProfile(state, track)));
  const downloaded = playlist.trackIDs
    .map((trackID) => state.tracks.find((track) => track.id === trackID && trackBelongsToActiveProfile(state, track))?.remoteID)
    .filter(Boolean);
  playlist.remoteSongIDs = mergePlaylistOrderWithPreservedItems(
    playlist.remoteSongIDs,
    downloaded,
    unresolved,
  );
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
    playlist.trackIDs = mergePlaylistOrderWithPreservedItems(
      playlist.trackIDs,
      downloaded,
      localOnly,
    );
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
      trackIDs: mergePlaylistOrderWithPreservedItems(
        previous?.trackIDs,
        downloaded,
        localOnly,
      ),
      remoteSongIDs,
      entryOrder: normalizedPlaylistEntryOrder(previous?.entryOrder),
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
