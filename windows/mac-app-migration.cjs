"use strict";

// The native macOS client stored its library and playback state in the
// UserDefaults domain belonging to the original production bundle.  Electron
// stores its state in userData instead.  Keep this bridge deliberately
// platform-specific and narrow: it only reads the known Resonance defaults and
// the two app-owned Application Support directories.

const os = require("node:os");
const path = require("node:path");
const { createHash } = require("node:crypto");
const { fileURLToPath } = require("node:url");
const fs = require("node:fs/promises");
const { execFile: nodeExecFile } = require("node:child_process");
const { promisify } = require("node:util");

const execFile = promisify(nodeExecFile);

const MAC_NATIVE_BUNDLE_IDENTIFIER = "com.gavindietrich.LikedSongsFocus";
const MAC_NATIVE_APPLICATION_SUPPORT_NAME = "Resonance";
const MAC_LEGACY_APPLICATION_SUPPORT_NAMES = Object.freeze(["Liked Songs"]);
const MAC_MIGRATION_ID = "migrate-macos-native-electron-v1";

const MAC_DEFAULT_KEYS = Object.freeze({
  library: "Resonance.library.v2",
  legacyTracks: "Resonance.importedTracks.v1",
  serverURL: "Resonance.serverURL.v1",
  volume: "Resonance.volume.v1",
  playbackRate: "Resonance.playbackRate.v1",
  crossfadeEnabled: "Resonance.crossfadeEnabled.v1",
  crossfadeSeconds: "Resonance.crossfadeSeconds.v1",
  shuffle: "Resonance.shuffle.v1",
  repeat: "Resonance.repeat.v1",
  currentTrack: "Resonance.currentTrack.v1",
  position: "Resonance.position.v1",
  history: "Resonance.history.v1",
  listeningHistory: "Resonance.listeningHistory.v1",
  playbackContext: "Resonance.playbackContext.v1",
  shuffleQueue: "Resonance.shuffleQueue.v1",
  transferModeUploadPrefix: "Resonance.transferMode.upload.v1.",
  transferModeDownloadPrefix: "Resonance.transferMode.download.v1.",
  remoteSongMetadata: "Resonance.remoteSongMetadata.v1",
  runInBackground: "Resonance.desktop.runInBackground.v1",
  discordRichPresence: "Resonance.desktop.discordRichPresence.v1",
  keybinds: "Resonance.desktop.keybinds.v1",
});

const FILE_CREDENTIAL_KEYS = Object.freeze({
  clientToken: "music-server-client-token",
  adminToken: "music-server-admin-token",
  accountSession: "music-server-account-session-v1",
});

function nativeMacPaths({ homeDirectory, targetUserData = null } = {}) {
  const home = String(homeDirectory || process.env.HOME || "").trim();
  if (!home) throw new Error("A macOS home directory is required for persistence migration.");
  const applicationSupport = path.join(home, "Library", "Application Support");
  const nativeSupport = path.join(applicationSupport, MAC_NATIVE_APPLICATION_SUPPORT_NAME);
  const electronUserData = targetUserData
    ? path.resolve(String(targetUserData))
    : nativeSupport;
  return {
    preferences: path.join(home, "Library", "Preferences", `${MAC_NATIVE_BUNDLE_IDENTIFIER}.plist`),
    nativeSupport,
    electronUserData,
    legacySupport: MAC_LEGACY_APPLICATION_SUPPORT_NAMES.map((name) => path.join(applicationSupport, name)),
    nativeCredentials: path.join(nativeSupport, "server-credentials.json"),
    electronCredentials: path.join(electronUserData, "server-credentials.json"),
    electronAccountSession: path.join(electronUserData, "account-session.json"),
  };
}

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value)
    && !(value instanceof Date) && !Buffer.isBuffer(value);
}

function base64Buffer(value) {
  if (Buffer.isBuffer(value)) return Buffer.from(value);
  if (value instanceof Uint8Array) return Buffer.from(value);
  if (isPlainObject(value) && Array.isArray(value.data)
      && value.type === "Buffer") {
    try { return Buffer.from(value.data); } catch { return null; }
  }
  if (typeof value !== "string" || !value) return null;
  // `plutil -convert json` represents plist <data> values as base64 text.
  // Reject malformed values instead of silently treating arbitrary strings as
  // binary data.
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(value) || value.length % 4 !== 0) return null;
  try {
    const decoded = Buffer.from(value, "base64");
    return decoded.length ? decoded : null;
  } catch {
    return null;
  }
}

function decodeJSONData(value) {
  // `plutil -convert json` leaves plist arrays as JavaScript arrays. Native
  // playback queues are stored exactly that way, while JSONEncoder data
  // values still arrive as base64 strings.
  if (isPlainObject(value) || Array.isArray(value)) return value;
  const bytes = base64Buffer(value);
  if (!bytes) return null;
  try { return JSON.parse(bytes.toString("utf8")); } catch { return null; }
}

function plistJSON(value) {
  if (isPlainObject(value)) return value;
  if (Buffer.isBuffer(value)) {
    try { return JSON.parse(value.toString("utf8")); } catch { return null; }
  }
  if (typeof value === "string") {
    try { return JSON.parse(value); } catch { return null; }
  }
  return null;
}

function nativeDate(value) {
  if (typeof value === "string") {
    const timestamp = Date.parse(value);
    return Number.isFinite(timestamp) ? new Date(timestamp).toISOString() : null;
  }
  const number = Number(value);
  if (!Number.isFinite(number)) return null;
  // Foundation's JSONEncoder default Date strategy is seconds from the
  // 2001-01-01 reference date. Also accept Unix seconds/milliseconds for
  // fixtures and older data that was manually serialized.
  const unixSeconds = number > 10_000_000_000
    ? number / 1000
    : number > 1_000_000_000
      ? number
      : number + 978307200;
  const date = new Date(unixSeconds * 1000);
  return Number.isFinite(date.getTime()) ? date.toISOString() : null;
}

function dataURLForArtwork(value) {
  const bytes = base64Buffer(value);
  if (!bytes || !bytes.length) return null;
  let mime = "application/octet-stream";
  if (bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) mime = "image/png";
  else if (bytes.subarray(0, 3).equals(Buffer.from([0xff, 0xd8, 0xff]))) mime = "image/jpeg";
  else if (bytes.subarray(0, 6).toString("ascii") === "GIF89a" || bytes.subarray(0, 6).toString("ascii") === "GIF87a") mime = "image/gif";
  else if (bytes.subarray(0, 4).toString("ascii") === "RIFF" && bytes.subarray(8, 12).toString("ascii") === "WEBP") mime = "image/webp";
  else if (bytes.subarray(4, 12).toString("ascii") === "ftypavif") mime = "image/avif";
  return `data:${mime};base64,${bytes.toString("base64")}`;
}

function nativeFilePath(value) {
  if (typeof value !== "string" || !value.trim()) return null;
  const candidate = value.trim();
  try {
    if (candidate.startsWith("file:")) return fileURLToPath(candidate);
  } catch {
    return null;
  }
  // URL Codable normally emits a file URL. Keep an absolute POSIX path as a
  // compatibility fallback for the oldest native library records.
  return candidate.startsWith("/") ? path.resolve(candidate) : null;
}

function rewriteMigratedPath(filePath, pathMappings = []) {
  if (typeof filePath !== "string" || !filePath || !Array.isArray(pathMappings)) return filePath;
  const sourcePath = path.resolve(filePath);
  let selected = null;
  for (const mapping of pathMappings) {
    if (!mapping || typeof mapping.source !== "string" || typeof mapping.destination !== "string") continue;
    const sourceRoot = path.resolve(mapping.source);
    if (sourcePath !== sourceRoot && !sourcePath.startsWith(`${sourceRoot}${path.sep}`)) continue;
    if (!selected || sourceRoot.length > selected.source.length) {
      selected = { source: sourceRoot, destination: path.resolve(mapping.destination) };
    }
  }
  if (!selected) return filePath;
  const suffix = path.relative(selected.source, sourcePath);
  return path.resolve(selected.destination, suffix);
}

function nativeTrack(value) {
  if (!isPlainObject(value)) return null;
  const id = typeof value.id === "string" ? value.id.trim() : "";
  if (!id) return null;
  const filePath = nativeFilePath(value.fileURL || value.filePath);
  const artwork = typeof value.artwork === "string" && value.artwork.startsWith("data:")
    ? value.artwork
    : dataURLForArtwork(value.artworkData);
  const kind = String(value.kind || "").toLowerCase().includes("video") ? "video" : "audio";
  return {
    id,
    title: typeof value.title === "string" ? value.title : "Untitled",
    artist: typeof value.artist === "string" ? value.artist : "Local file",
    album: typeof value.album === "string" ? value.album : "Unknown Album",
    duration: Number.isFinite(Number(value.duration)) ? Math.max(0, Number(value.duration)) : 0,
    kind,
    mediaKind: kind,
    artwork,
    artworkURL: typeof value.artworkURL === "string" ? value.artworkURL : null,
    filePath,
    available: Boolean(filePath),
    missing: !filePath,
    storageLocation: null,
    remoteID: typeof value.remoteID === "string" ? value.remoteID : null,
    sourceServer: typeof value.sourceServer === "string" ? value.sourceServer : null,
    syncProfileID: typeof value.syncProfileID === "string" ? value.syncProfileID : null,
    sourceURL: typeof value.sourceURL === "string" ? value.sourceURL : null,
    downloadSourceURL: typeof value.downloadSourceURL === "string" ? value.downloadSourceURL : null,
    sourceSha256: typeof value.sourceSHA256 === "string" ? value.sourceSHA256 : null,
    contentSha256: typeof value.contentSHA256 === "string" ? value.contentSHA256 : null,
    preservesUnlinkedImport: typeof value.preservesUnlinkedImport === "boolean" ? value.preservesUnlinkedImport : null,
    dateAdded: nativeDate(value.dateAdded) || new Date().toISOString(),
  };
}

function nativePlaylist(value) {
  if (!isPlainObject(value)) return null;
  const id = typeof value.id === "string" ? value.id.trim() : "";
  const name = typeof value.name === "string" ? value.name : "Playlist";
  if (!id) return null;
  return {
    id,
    name,
    trackIDs: Array.isArray(value.trackIDs) ? value.trackIDs.filter((item) => typeof item === "string") : [],
    isSystem: Boolean(value.isSystem),
    remoteSongIDs: Array.isArray(value.remoteSongIDs) ? value.remoteSongIDs.filter((item) => typeof item === "string") : [],
    entryOrder: Array.isArray(value.entryOrder) ? value.entryOrder.filter((item) => typeof item === "string") : [],
    // Native artwork is an enum, while Electron renders artwork from tracks.
    artwork: null,
  };
}

function nativeHistoryEntry(value) {
  if (!isPlainObject(value)) return null;
  const id = typeof value.id === "string" ? value.id.trim() : "";
  const trackID = typeof value.trackID === "string" ? value.trackID.trim() : "";
  const startedAt = nativeDate(value.startedAt);
  if (!id || !trackID || !startedAt) return null;
  return {
    id,
    trackID,
    profileID: typeof value.syncProfileID === "string" && value.syncProfileID ? value.syncProfileID : "default",
    serverOrigin: typeof value.serverOrigin === "string" ? value.serverOrigin : null,
    startedAt,
    listenedSeconds: Math.max(0, Number(value.listenedSeconds) || 0),
    remoteID: typeof value.remoteSongID === "string" ? value.remoteSongID : null,
    title: typeof value.title === "string" ? value.title : null,
    artist: typeof value.artist === "string" ? value.artist : null,
    album: typeof value.album === "string" ? value.album : null,
    duration: Number.isFinite(Number(value.duration)) ? Math.max(0, Number(value.duration)) : null,
    artworkURL: typeof value.artworkURL === "string" ? value.artworkURL : null,
    originatedOnThisDevice: value.originatedOnThisDevice !== false,
  };
}

function nativeAccountSession(value) {
  if (!isPlainObject(value)) return null;
  const session = { ...value };
  const expiresAt = nativeDate(value.expiresAt);
  // Native JSONEncoder uses Foundation reference-date seconds for Date. The
  // Electron session validator uses Unix milliseconds, so normalize only the
  // date field while retaining every other account field verbatim.
  if (expiresAt) session.expiresAt = Date.parse(expiresAt);
  return session;
}

function safeArray(value) {
  return Array.isArray(value) ? value : [];
}

function uniqueStrings(...collections) {
  return [...new Set(collections.flatMap(safeArray).filter((item) => typeof item === "string" && item))];
}

const NATIVE_UPLOAD_MODES = new Set(["local_file", "server_source_link", "reviewed_match"]);
const NATIVE_DOWNLOAD_MODES = new Set(["verified_file_cache", "stream_only"]);
const LEGACY_PRODUCTION_ORIGIN = "https://music.unblocked.mov";
const PRODUCTION_ORIGIN = "https://resonance-core.blithe-haven-9710.chatgpt.site";

function nativeServerOrigin(value) {
  try {
    const url = new URL(String(value || "").trim());
    if (!["http:", "https:"].includes(url.protocol) || !url.hostname) return "";
    const origin = url.origin;
    return origin === LEGACY_PRODUCTION_ORIGIN ? PRODUCTION_ORIGIN : origin;
  } catch {
    return "";
  }
}

function nativeRawServerOrigin(value) {
  try {
    const url = new URL(String(value || "").trim());
    if (!["http:", "https:"].includes(url.protocol) || !url.hostname) return "";
    return url.origin;
  } catch {
    return "";
  }
}

function nativeTransferModeScope(origin, profileID) {
  return createHash("sha256")
    .update(`${origin}\u0000${profileID}`)
    .digest("hex");
}

function nativeTransferPreferences(defaults, serverURL, profileID) {
  const origin = nativeServerOrigin(serverURL);
  const normalizedProfileID = String(profileID || "default").trim() || "default";
  if (!origin) return {};
  // Native UserDefaults keys were scoped to the server origin at the time they
  // were written. Read both the historical and mapped production origins, but
  // always persist the Electron preference under the current canonical origin.
  const lookupOrigins = [...new Set([nativeRawServerOrigin(serverURL), origin].filter(Boolean))];
  const scopes = lookupOrigins.map((lookupOrigin) => nativeTransferModeScope(lookupOrigin, normalizedProfileID));
  const upload = scopes
    .map((scope) => defaults[`${MAC_DEFAULT_KEYS.transferModeUploadPrefix}${scope}`])
    .find((value) => NATIVE_UPLOAD_MODES.has(value));
  const download = scopes
    .map((scope) => defaults[`${MAC_DEFAULT_KEYS.transferModeDownloadPrefix}${scope}`])
    .find((value) => NATIVE_DOWNLOAD_MODES.has(value));
  if (!NATIVE_UPLOAD_MODES.has(upload) && !NATIVE_DOWNLOAD_MODES.has(download)) return {};
  const key = `${origin}#profile=${normalizedProfileID.slice(0, 128)}`;
  return {
    [key]: {
      uploadMode: NATIVE_UPLOAD_MODES.has(upload) ? upload : "local_file",
      downloadMode: NATIVE_DOWNLOAD_MODES.has(download) ? download : "verified_file_cache",
    },
  };
}

function mergeRecordsByID(existingValues, nativeValues, mergeRecord = (existing) => existing) {
  const nativeByID = new Map(safeArray(nativeValues)
    .filter((item) => isPlainObject(item) && typeof item.id === "string" && item.id)
    .map((item) => [item.id, item]));
  const result = [];
  const seen = new Set();
  for (const existing of safeArray(existingValues)) {
    if (!isPlainObject(existing) || typeof existing.id !== "string" || !existing.id || seen.has(existing.id)) continue;
    result.push(mergeRecord(existing, nativeByID.get(existing.id)));
    seen.add(existing.id);
  }
  for (const native of nativeByID.values()) {
    if (!seen.has(native.id)) result.push(native);
  }
  return result;
}

function mergeMacNativeState(existingValue, nativeValue) {
  const existing = isPlainObject(existingValue) ? existingValue : {};
  const native = isPlainObject(nativeValue) ? nativeValue : {};
  const merged = { ...native, ...existing };
  merged.tracks = mergeRecordsByID(existing.tracks, native.tracks, (current, fallback) => ({
    ...(fallback || {}),
    ...current,
  }));
  merged.playlists = mergeRecordsByID(existing.playlists, native.playlists, (current, fallback) => ({
    ...(fallback || {}),
    ...current,
    trackIDs: uniqueStrings(current.trackIDs, fallback?.trackIDs),
    remoteSongIDs: uniqueStrings(current.remoteSongIDs, fallback?.remoteSongIDs),
    entryOrder: uniqueStrings(current.entryOrder, fallback?.entryOrder),
  }));
  merged.listeningHistory = mergeRecordsByID(existing.listeningHistory, native.listeningHistory);
  merged.syncProfiles = mergeRecordsByID(existing.syncProfiles, native.syncProfiles);
  for (const key of [
    "favorites",
    "knownRemotePlaylistIDs",
    "dirtyPlaylistIDs",
    "deletedPlaylistIDs",
    "remoteLikedSongIDs",
    "dirtyRemoteLikeSongIDs",
    "dirtyClipRangeKeys",
    "deletedClipRangeKeys",
    "completedMigrations",
  ]) {
    merged[key] = uniqueStrings(existing[key], native[key]);
  }
  merged.clipRanges = { ...(isPlainObject(native.clipRanges) ? native.clipRanges : {}), ...(isPlainObject(existing.clipRanges) ? existing.clipRanges : {}) };
  merged.profileStates = { ...(isPlainObject(native.profileStates) ? native.profileStates : {}), ...(isPlainObject(existing.profileStates) ? existing.profileStates : {}) };
  merged.serverTransferPreferences = {
    ...(isPlainObject(native.serverTransferPreferences) ? native.serverTransferPreferences : {}),
    ...(isPlainObject(existing.serverTransferPreferences) ? existing.serverTransferPreferences : {}),
  };
  merged.remoteSongMetadataCache = {
    ...(isPlainObject(native.remoteSongMetadataCache) ? native.remoteSongMetadataCache : {}),
    ...(isPlainObject(existing.remoteSongMetadataCache) ? existing.remoteSongMetadataCache : {}),
  };
  merged.appPreferences = {
    ...(isPlainObject(native.appPreferences) ? native.appPreferences : {}),
    ...(isPlainObject(existing.appPreferences) ? existing.appPreferences : {}),
  };
  return merged;
}

function mapRemoteMetadata(value) {
  const parsed = decodeJSONData(value);
  if (!isPlainObject(parsed)) return {};
  const result = {};
  for (const [cacheKey, item] of Object.entries(parsed)) {
    if (!isPlainObject(item)) continue;
    const metadata = isPlainObject(item.metadata) ? item.metadata : item;
    const sourceURL = typeof metadata.sourceURL === "string" ? metadata.sourceURL : null;
    const title = typeof metadata.title === "string" ? metadata.title : null;
    const artist = typeof metadata.artist === "string" ? metadata.artist : null;
    const cachedAt = nativeDate(item.cachedAt);
    if (!sourceURL || !title || !artist || !cachedAt) continue;
    const mediaKind = String(cacheKey).startsWith("video:") ? "video" : "audio";
    result[`${mediaKind}:${sourceURL}`] = {
      sourceURL,
      mediaKind,
      title,
      artist,
      album: typeof metadata.album === "string" ? metadata.album : null,
      duration: Number.isFinite(Number(metadata.durationSeconds)) ? Number(metadata.durationSeconds) : null,
      artworkURL: typeof metadata.artworkURL === "string" ? metadata.artworkURL : null,
      cachedAt,
    };
  }
  return result;
}

function nativeMacState(defaults = {}, { pathMappings = [] } = {}) {
  const library = decodeJSONData(defaults[MAC_DEFAULT_KEYS.library]);
  const legacyTracks = decodeJSONData(defaults[MAC_DEFAULT_KEYS.legacyTracks]);
  const tracks = safeArray(library?.tracks || legacyTracks)
    .map(nativeTrack)
    .filter(Boolean)
    .map((track) => ({ ...track, filePath: rewriteMigratedPath(track.filePath, pathMappings) }));
  const playlists = safeArray(library?.playlists).map(nativePlaylist).filter(Boolean);
  const syncProfileID = typeof library?.syncProfileID === "string" && library.syncProfileID
    ? library.syncProfileID
    : "default";
  const syncProfileName = typeof library?.syncProfileName === "string" && library.syncProfileName
    ? library.syncProfileName
    : "Default";
  const defaultProfile = { id: syncProfileID, name: syncProfileName, is_default: true };
  const contextIDs = decodeJSONData(defaults[MAC_DEFAULT_KEYS.playbackContext]);
  const shuffleQueue = decodeJSONData(defaults[MAC_DEFAULT_KEYS.shuffleQueue]);
  const history = decodeJSONData(defaults[MAC_DEFAULT_KEYS.listeningHistory]);
  const serverURL = typeof defaults[MAC_DEFAULT_KEYS.serverURL] === "string"
    ? defaults[MAC_DEFAULT_KEYS.serverURL]
    : "";
  const state = {
    tracks,
    playlists,
    favorites: safeArray(library?.favorites).filter((item) => typeof item === "string"),
    serverURL,
    volume: Number.isFinite(Number(defaults[MAC_DEFAULT_KEYS.volume])) ? Number(defaults[MAC_DEFAULT_KEYS.volume]) : 0.78,
    playbackRate: Number.isFinite(Number(defaults[MAC_DEFAULT_KEYS.playbackRate])) ? Number(defaults[MAC_DEFAULT_KEYS.playbackRate]) : 1,
    shuffle: Boolean(defaults[MAC_DEFAULT_KEYS.shuffle]),
    repeat: Boolean(defaults[MAC_DEFAULT_KEYS.repeat]),
    currentTrackID: typeof defaults[MAC_DEFAULT_KEYS.currentTrack] === "string" ? defaults[MAC_DEFAULT_KEYS.currentTrack] : null,
    position: Number.isFinite(Number(defaults[MAC_DEFAULT_KEYS.position])) ? Number(defaults[MAC_DEFAULT_KEYS.position]) : 0,
    playbackQueueIDs: safeArray(shuffleQueue).filter((item) => typeof item === "string"),
    playbackSourceQueueIDs: safeArray(contextIDs).filter((item) => typeof item === "string"),
    playbackPlaylistID: null,
    playlistRevision: Number.isInteger(Number(library?.playlistRevision)) ? Number(library.playlistRevision) : 0,
    knownRemotePlaylistIDs: safeArray(library?.knownRemotePlaylistIDs).filter((item) => typeof item === "string"),
    dirtyPlaylistIDs: safeArray(library?.dirtyPlaylistIDs).filter((item) => typeof item === "string"),
    deletedPlaylistIDs: safeArray(library?.deletedPlaylistIDs).filter((item) => typeof item === "string"),
    playlistSyncServerURL: typeof library?.playlistSyncServerURL === "string" ? library.playlistSyncServerURL : null,
    syncProfileID,
    syncProfiles: [defaultProfile],
    profileStates: {},
    remoteLikedSongIDs: safeArray(library?.remoteLikedSongIDs).filter((item) => typeof item === "string"),
    dirtyRemoteLikeSongIDs: safeArray(library?.dirtyRemoteLikeSongIDs).filter((item) => typeof item === "string"),
    likesDirty: Boolean(library?.likesDirty),
    serverTransferPreferences: {
      ...(isPlainObject(library?.serverTransferPreferences) ? library.serverTransferPreferences : {}),
      ...nativeTransferPreferences(defaults, serverURL, syncProfileID),
    },
    clipRanges: isPlainObject(library?.clipRanges) ? library.clipRanges : {},
    dirtyClipRangeKeys: safeArray(library?.dirtyClipRangeKeys).filter((item) => typeof item === "string"),
    deletedClipRangeKeys: safeArray(library?.deletedClipRangeKeys).filter((item) => typeof item === "string"),
    listeningHistory: safeArray(history).map(nativeHistoryEntry).filter(Boolean),
    remoteSongMetadataCache: mapRemoteMetadata(defaults[MAC_DEFAULT_KEYS.remoteSongMetadata]),
    appPreferences: {
      theme: "midnight",
      runInBackground: Boolean(defaults[MAC_DEFAULT_KEYS.runInBackground]),
      discordRichPresence: Boolean(defaults[MAC_DEFAULT_KEYS.discordRichPresence]),
      crossfadeEnabled: Boolean(defaults[MAC_DEFAULT_KEYS.crossfadeEnabled]),
      crossfadeSeconds: Number.isFinite(Number(defaults[MAC_DEFAULT_KEYS.crossfadeSeconds]))
        ? Number(defaults[MAC_DEFAULT_KEYS.crossfadeSeconds])
        : 5,
      keybinds: decodeJSONData(defaults[MAC_DEFAULT_KEYS.keybinds]) || {},
    },
    completedMigrations: [...safeArray(library?.completedMigrations).filter((item) => typeof item === "string"), MAC_MIGRATION_ID],
  };
  if (!state.playlists.length) {
    state.playlists = [{ id: "liked", name: "Liked Songs", trackIDs: state.favorites, isSystem: true }];
  }
  return state;
}

function nativeCredentialDocument(value) {
  if (!isPlainObject(value)) return { values: {}, clientToken: "", adminToken: "", accountSession: null };
  const values = isPlainObject(value.values) ? value.values : value;
  const clientToken = typeof values[FILE_CREDENTIAL_KEYS.clientToken] === "string"
    ? values[FILE_CREDENTIAL_KEYS.clientToken]
    : (typeof value.clientToken === "string" ? value.clientToken : "");
  const adminToken = typeof values[FILE_CREDENTIAL_KEYS.adminToken] === "string"
    ? values[FILE_CREDENTIAL_KEYS.adminToken]
    : (typeof value.adminToken === "string" ? value.adminToken : "");
  const rawSession = values[FILE_CREDENTIAL_KEYS.accountSession];
  let accountSession = null;
  if (isPlainObject(rawSession)) accountSession = nativeAccountSession(rawSession);
  else if (typeof rawSession === "string") {
    try { accountSession = nativeAccountSession(JSON.parse(rawSession)); } catch { accountSession = null; }
  }
  return { values, clientToken, adminToken, accountSession };
}

function electronCredentialDocument({ clientToken = "", adminToken = "", accountSession = null, extraValues = {} } = {}) {
  const values = isPlainObject(extraValues) ? { ...extraValues } : {};
  if (clientToken) values[FILE_CREDENTIAL_KEYS.clientToken] = String(clientToken);
  else delete values[FILE_CREDENTIAL_KEYS.clientToken];
  if (adminToken) values[FILE_CREDENTIAL_KEYS.adminToken] = String(adminToken);
  else delete values[FILE_CREDENTIAL_KEYS.adminToken];
  if (accountSession) values[FILE_CREDENTIAL_KEYS.accountSession] = JSON.stringify(accountSession);
  else delete values[FILE_CREDENTIAL_KEYS.accountSession];
  return { values };
}

async function readJSONFile(filePath, readFile = fs.readFile) {
  try { return JSON.parse(await readFile(filePath, "utf8")); } catch { return null; }
}

async function readNativeCredentialFile(filePath, readFile = fs.readFile) {
  return nativeCredentialDocument(await readJSONFile(filePath, readFile));
}

async function readMacDefaults({ paths, platform = process.platform, bundleIdentifier = MAC_NATIVE_BUNDLE_IDENTIFIER, exec = execFile, readFile = fs.readFile } = {}) {
  if (platform !== "darwin") return null;
  const preferencePath = paths?.preferences;
  // `defaults export` asks cfprefsd for the current persistent values. This is
  // more reliable than reading the plist while the native app was recently
  // running. Fall back to plutil for tests and older macOS environments.
  try {
    const result = await exec("/usr/bin/defaults", ["export", bundleIdentifier, "-"], {
      encoding: "buffer",
      maxBuffer: 32 * 1024 * 1024,
    });
    const plist = result?.stdout || result;
    const temporaryRoot = await fs.mkdtemp(path.join(os.tmpdir(), "resonance-mac-prefs-"));
    const temporaryPlist = path.join(temporaryRoot, "native.plist");
    try {
      await fs.writeFile(temporaryPlist, plist);
      const json = await exec("/usr/bin/plutil", ["-convert", "json", "-o", "-", "--", temporaryPlist], {
        encoding: "utf8",
        maxBuffer: 32 * 1024 * 1024,
      });
      if (json?.stdout) return plistJSON(json.stdout);
    } finally {
      await fs.rm(temporaryRoot, { recursive: true, force: true }).catch(() => undefined);
    }
  } catch {
    // The plist fallback below is intentionally best effort.
  }
  if (!preferencePath) return null;
  try {
    const json = await exec("/usr/bin/plutil", ["-convert", "json", "-o", "-", "--", preferencePath], {
      encoding: "utf8",
      maxBuffer: 32 * 1024 * 1024,
    });
    return plistJSON(json?.stdout || json);
  } catch {
    try { return plistJSON(await readFile(preferencePath, "utf8")); } catch { return null; }
  }
}

function sameFileContents(source, destination, readFile = fs.readFile) {
  return Promise.all([readFile(source), readFile(destination)])
    .then(([left, right]) => left.equals(right))
    .catch(() => false);
}

async function sameNativeEntryContents(source, destination, fileSystem = fs) {
  let sourceStat;
  let destinationStat;
  try {
    sourceStat = await fileSystem.stat(source);
    destinationStat = await fileSystem.stat(destination);
  } catch {
    return false;
  }
  if (sourceStat.isFile() && destinationStat.isFile()) {
    return sameFileContents(source, destination, fileSystem.readFile.bind(fileSystem));
  }
  if (!sourceStat.isDirectory() || !destinationStat.isDirectory()) return false;
  let entries;
  try {
    entries = await fileSystem.readdir(source, { withFileTypes: true });
  } catch {
    return false;
  }
  for (const entry of entries) {
    if (!await sameNativeEntryContents(
      path.join(source, entry.name),
      path.join(destination, entry.name),
      fileSystem,
    )) return false;
  }
  return true;
}

async function matchingRecoveryPath(directory, name, source, fileSystem = fs) {
  let candidate = path.join(directory, name);
  let counter = 2;
  while (true) {
    try {
      await fileSystem.access(candidate);
      if (await sameNativeEntryContents(source, candidate, fileSystem)) return candidate;
      candidate = path.join(directory, `${name}.${counter}`);
      counter += 1;
    } catch {
      return null;
    }
  }
}

async function uniqueRecoveryPath(directory, name, access = fs.access) {
  let candidate = path.join(directory, name);
  let counter = 2;
  while (true) {
    try {
      await access(candidate);
      candidate = path.join(directory, `${name}.${counter}`);
      counter += 1;
    } catch {
      return candidate;
    }
  }
}

async function mergeNativeDirectory(source, destination, {
  fileSystem = fs,
  recoveryName = "Legacy Recovery",
  preserveSource = false,
} = {}) {
  if (path.resolve(source) === path.resolve(destination)) return { moved: false, conflicts: 0, pathMappings: [] };
  try { await fileSystem.access(source); } catch { return { moved: false, conflicts: 0, pathMappings: [] }; }
  const pathMappings = [];
  const recordMapping = (from, to) => {
    pathMappings.push({ source: path.resolve(from), destination: path.resolve(to) });
  };
  try {
    await fileSystem.access(destination);
  } catch {
    await fileSystem.mkdir(path.dirname(destination), { recursive: true });
    if (preserveSource) await fileSystem.cp(source, destination, { recursive: true, force: false });
    else await fileSystem.rename(source, destination);
    recordMapping(source, destination);
    return { moved: true, conflicts: 0, preservedSource: preserveSource, pathMappings };
  }
  let conflicts = 0;
  await fileSystem.mkdir(destination, { recursive: true });
  const recoveryRoot = path.join(destination, recoveryName);
  async function merge(sourceDirectory, destinationDirectory) {
    const entries = await fileSystem.readdir(sourceDirectory, { withFileTypes: true });
    for (const entry of entries) {
      const from = path.join(sourceDirectory, entry.name);
      const to = path.join(destinationDirectory, entry.name);
      let destinationEntry = null;
      try { destinationEntry = await fileSystem.stat(to); } catch { /* missing */ }
      if (!destinationEntry) {
        if (preserveSource) await fileSystem.cp(from, to, { recursive: entry.isDirectory(), force: false });
        else await fileSystem.rename(from, to);
        recordMapping(from, to);
        continue;
      }
      if (entry.isDirectory() && destinationEntry.isDirectory()) {
        await merge(from, to);
        if (!preserveSource) await fileSystem.rm(from, { recursive: true, force: true });
        continue;
      }
      if (!entry.isDirectory() && destinationEntry.isFile()
          && await sameFileContents(from, to, fileSystem.readFile.bind(fileSystem))) {
        if (!preserveSource) await fileSystem.rm(from, { force: true });
        recordMapping(from, to);
        continue;
      }
      conflicts += 1;
      await fileSystem.mkdir(recoveryRoot, { recursive: true });
      const matchingRecovery = await matchingRecoveryPath(
        recoveryRoot,
        entry.name,
        from,
        fileSystem,
      );
      if (matchingRecovery) {
        recordMapping(from, matchingRecovery);
        continue;
      }
      const recoveryPath = await uniqueRecoveryPath(
        recoveryRoot,
        entry.name,
        fileSystem.access.bind(fileSystem),
      );
      if (preserveSource) await fileSystem.cp(from, recoveryPath, { recursive: entry.isDirectory(), force: false });
      else await fileSystem.rename(from, recoveryPath);
      recordMapping(from, recoveryPath);
    }
  }
  await merge(source, destination);
  if (!preserveSource) {
    try { await fileSystem.rm(source, { recursive: true, force: true }); } catch { /* leave for retry */ }
  }
  return { moved: true, conflicts, preservedSource: preserveSource, pathMappings };
}

async function verifyNativePathMappings(pathMappings, fileSystem = fs) {
  if (!Array.isArray(pathMappings)) return false;
  for (const mapping of pathMappings) {
    if (!mapping || typeof mapping.source !== "string" || typeof mapping.destination !== "string") return false;
    if (!await sameNativeEntryContents(mapping.source, mapping.destination, fileSystem)) return false;
  }
  return true;
}

async function cleanupMacNativeData(migration, { fileSystem = fs } = {}) {
  if (!migration?.copyVerified || !Array.isArray(migration.sourceCleanupPaths)) {
    return { cleaned: false, paths: [] };
  }
  const cleaned = [];
  for (const source of migration.sourceCleanupPaths) {
    if (typeof source !== "string" || !source) continue;
    if (migration.paths && path.resolve(source) === path.resolve(migration.paths.electronUserData)) continue;
    await fileSystem.rm(source, { recursive: true, force: true });
    cleaned.push(source);
  }
  return { cleaned: true, paths: cleaned };
}

async function migrateMacNativeData({
  homeDirectory,
  targetUserData,
  platform = process.platform,
  defaults = undefined,
  readFile = fs.readFile,
  exec = execFile,
  fileSystem = fs,
  preserveSources = false,
  deferSourceDeletion = false,
} = {}) {
  if (platform !== "darwin") return { migrated: false, state: null, credentials: null, accountSession: null };
  const paths = nativeMacPaths({ homeDirectory, targetUserData });
  // Packaged upgrades copy first and let main.cjs delete the native roots only
  // after the rewritten library and credentials have been persisted. Preview
  // launches remain source-preserving for the lifetime of the process.
  const copyOnly = Boolean(preserveSources || deferSourceDeletion);
  // Read credentials before merging the source support directory. The merge
  // may move that file into Electron's target root when a worktree userData
  // path is in use.
  const nativeCredentials = await readNativeCredentialFile(paths.nativeCredentials, readFile);
  const supportMigrations = [];
  for (const legacySupport of paths.legacySupport) {
    supportMigrations.push(await mergeNativeDirectory(legacySupport, paths.electronUserData, {
      fileSystem,
      preserveSource: copyOnly,
    }));
  }
  // A native build may have already moved the old support directory to
  // `Resonance`, while a development Electron instance intentionally uses a
  // worktree-specific userData path. Carry over that app-owned cache and
  // profile-picture data as well, retaining conflicts with the same recovery
  // policy. This is a no-op for the packaged macOS path, where both roots are
  // `~/Library/Application Support/Resonance`.
  if (path.resolve(paths.nativeSupport) !== path.resolve(paths.electronUserData)) {
    supportMigrations.push(await mergeNativeDirectory(paths.nativeSupport, paths.electronUserData, {
      fileSystem,
      preserveSource: copyOnly,
    }));
  }
  const nativeDefaults = defaults || await readMacDefaults({ paths, platform, exec, readFile });
  const pathMappings = supportMigrations.flatMap((migration) => migration.pathMappings || []);
  const copyVerified = copyOnly
    ? await verifyNativePathMappings(pathMappings, fileSystem)
    : true;
  const sourceCleanupPaths = deferSourceDeletion && !preserveSources
    ? [
      ...paths.legacySupport,
      ...(path.resolve(paths.nativeSupport) === path.resolve(paths.electronUserData) ? [] : [paths.nativeSupport]),
    ]
    : [];
  return {
    migrated: true,
    paths,
    supportMigrations,
    copyVerified,
    sourceCleanupPaths,
    defaults: nativeDefaults,
    // A failed defaults/plutil read is not an empty native library. Leave the
    // state absent so startup retries the import without committing data loss.
    state: nativeDefaults && copyVerified ? nativeMacState(nativeDefaults, { pathMappings }) : null,
    credentials: {
      clientToken: nativeCredentials.clientToken,
      adminToken: nativeCredentials.adminToken,
    },
    accountSession: nativeCredentials.accountSession,
    credentialValues: nativeCredentials.values,
  };
}

module.exports = {
  FILE_CREDENTIAL_KEYS,
  MAC_DEFAULT_KEYS,
  MAC_LEGACY_APPLICATION_SUPPORT_NAMES,
  MAC_MIGRATION_ID,
  MAC_NATIVE_APPLICATION_SUPPORT_NAME,
  MAC_NATIVE_BUNDLE_IDENTIFIER,
  dataURLForArtwork,
  cleanupMacNativeData,
  electronCredentialDocument,
  mergeNativeDirectory,
  mergeMacNativeState,
  nativeCredentialDocument,
  nativeDate,
  nativeMacPaths,
  nativeMacState,
  nativeTrack,
  readMacDefaults,
  readNativeCredentialFile,
  migrateMacNativeData,
};
