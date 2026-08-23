import { createEmptyState, SAFE_CLIENT_CONFIG } from "./core.js";

/**
 * Browser-only renderer bridge.
 *
 * Electron supplies the real bridge from preload.cjs. A normal browser does
 * not, but the renderer should still be useful for visual and interaction
 * testing. This module provides deterministic local fixtures and safe no-op
 * implementations for the main-process capabilities. It is intentionally
 * loaded before app.js and leaves an existing Electron bridge untouched.
 */

const BROWSER_STATE_KEY = "resonance.browser.state.v1";
const BROWSER_RUNTIME_VERSION = "1";
const BROWSER_STATE_RESET_EVENT = "resonance:browser-state-reset";
const DEFAULT_CAPACITY_BYTES = 64 * 1024 * 1024 * 1024;
const FIXTURE_TRACK_DURATIONS = Object.freeze([186, 242, 205, 278, 194, 221]);
const browserAudioURLs = new Map();

function clone(value) {
  if (typeof structuredClone === "function") return structuredClone(value);
  return JSON.parse(JSON.stringify(value));
}

function browserArtwork(title, first, second) {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="640" height="640" viewBox="0 0 640 640"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop stop-color="${first}"/><stop offset="1" stop-color="${second}"/></linearGradient></defs><rect width="640" height="640" rx="96" fill="url(#g)"/><circle cx="510" cy="120" r="150" fill="#ffffff" opacity=".1"/><path d="M150 422c85-103 169-152 252-148 29 2 55 11 78 26v93c-29-18-58-26-87-24-63 4-123 48-181 132z" fill="#fff" opacity=".9"/><text x="56" y="112" fill="#fff" font-family="system-ui,sans-serif" font-size="34" font-weight="700" opacity=".85">${title}</text></svg>`;
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

function createBrowserAudioURL(durationSeconds = 1) {
  const duration = Math.max(1, Math.round(Number(durationSeconds) || 1));
  if (browserAudioURLs.has(duration)) return browserAudioURLs.get(duration);
  if (typeof Blob !== "function" || typeof URL === "undefined" || typeof URL.createObjectURL !== "function") return "";
  try {
    // A valid silent WAV keeps transport controls testable without fetching or
    // embedding a copyrighted media fixture. Its duration must match the
    // metadata below: app.js correctly trusts playable media metadata over a
    // stale stored value, so a one-second fixture would rewrite every track
    // to 0:01 as soon as it was played.
    // 4 kHz keeps the complete six-track fixture around 11 MB while still
    // using a broadly supported PCM WAV format.
    const sampleRate = 4_000;
    const sampleCount = sampleRate * duration;
    const bytes = new Uint8Array(44 + sampleCount * 2);
    const view = new DataView(bytes.buffer);
    const writeText = (offset, value) => {
      for (let index = 0; index < value.length; index += 1) bytes[offset + index] = value.charCodeAt(index);
    };
    writeText(0, "RIFF");
    view.setUint32(4, bytes.length - 8, true);
    writeText(8, "WAVEfmt ");
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, 1, true);
    view.setUint32(24, sampleRate, true);
    view.setUint32(28, sampleRate * 2, true);
    view.setUint16(32, 2, true);
    view.setUint16(34, 16, true);
    writeText(36, "data");
    view.setUint32(40, sampleCount * 2, true);
    const audioURL = URL.createObjectURL(new Blob([bytes], { type: "audio/wav" }));
    browserAudioURLs.set(duration, audioURL);
    return audioURL;
  } catch {
    return "";
  }
}

function fixtureAudioURLs() {
  return FIXTURE_TRACK_DURATIONS.map((duration) => createBrowserAudioURL(duration));
}

function sampleTracks(audioURLs) {
  const urls = Array.isArray(audioURLs) ? audioURLs : [audioURLs];
  const now = new Date();
  const artwork = [
    browserArtwork("MORNING", "#5b21b6", "#0891b2"),
    browserArtwork("NIGHT", "#be123c", "#7c3aed"),
    browserArtwork("GLOW", "#0369a1", "#0f766e"),
    browserArtwork("DRIFT", "#c2410c", "#7e22ce"),
    browserArtwork("FIELD", "#166534", "#0f766e"),
    browserArtwork("LIGHT", "#a16207", "#c2410c"),
  ];
  const entries = [
    ["browser-morning", "Morning Signal", "Resonance Ensemble", "First Light", 186, 1_800_000, "local"],
    ["browser-night", "Night Drive", "Low Frequency Club", "After Hours", 242, 2_300_000, "local"],
    ["browser-glow", "Soft Focus", "Mira Vale", "Luminous", 205, 2_000_000, "local"],
    ["browser-drift", "Drift State", "Kite Theory", "Parallel Lines", 278, 2_700_000, "local"],
    ["browser-field", "Open Field", "Northline", "Small Hours", 194, 1_900_000, "local"],
    ["browser-light", "Late Light", "The Quiet Hours", "Signal Bloom", 221, 2_100_000, "local"],
  ];
  return entries.map(([id, title, artist, album, duration, size, storageLocation], index) => ({
    id,
    title,
    artist,
    album,
    duration,
    size,
    // Browser fixtures have no real filesystem location. Leaving filePath
    // empty keeps the desktop-only "Show in folder" action out of the
    // browser context menu instead of exposing a no-op action.
    filePath: null,
    fileUrl: urls[index] || urls[0] || "",
    sourceURL: `https://example.com/resonance/${id}`,
    artwork: artwork[index],
    artworkURL: artwork[index],
    dateAdded: new Date(now.getTime() - index * 86_400_000).toISOString(),
    available: true,
    missing: false,
    storageLocation,
  }));
}

function createFixtureState(audioURLs) {
  const state = createEmptyState();
  const tracks = sampleTracks(audioURLs);
  state.tracks = tracks;
  state.favorites = tracks.slice(0, 2).map(({ id }) => id);
  state.playlists = [
    { id: "liked", name: "Liked Songs", trackIDs: state.favorites, isSystem: true },
    { id: "browser-focus", name: "Focus Set", trackIDs: tracks.slice(0, 4).map(({ id }) => id), isSystem: false },
    { id: "browser-evening", name: "Evening Rotation", trackIDs: tracks.slice(2).map(({ id }) => id), isSystem: false },
  ];
  state.currentTrackID = tracks[0]?.id || null;
  state.playbackQueueIDs = tracks.map(({ id }) => id);
  state.playbackSourceQueueIDs = [...state.playbackQueueIDs];
  state.appPreferences = {
    ...state.appPreferences,
    theme: "midnight",
  };
  return state;
}

function defaultBrowserStorage() {
  try {
    return globalThis?.localStorage || null;
  } catch {
    // Some browsers expose localStorage through a getter that throws when
    // storage is disabled or blocked by the current origin.
    return null;
  }
}

function safeStorage(storage) {
  return storage && typeof storage.getItem === "function" && typeof storage.setItem === "function"
    ? storage
    : null;
}

function loadStoredState(storage, audioURLs) {
  if (!storage) return createFixtureState(audioURLs);
  try {
    const encoded = storage.getItem(BROWSER_STATE_KEY);
    if (!encoded) return createFixtureState(audioURLs);
    const parsed = JSON.parse(encoded);
    if (!parsed || parsed.runtimeVersion !== BROWSER_RUNTIME_VERSION || !parsed.state) {
      return createFixtureState(audioURLs);
    }
    const state = { ...createFixtureState(audioURLs), ...parsed.state };
    const fixtureTracks = new Map(sampleTracks(audioURLs).map((track) => [track.id, track]));
    state.tracks = (Array.isArray(state.tracks) ? state.tracks : []).map((track) => {
      const fixture = fixtureTracks.get(track?.id);
      return fixture ? { ...fixture, ...track, filePath: null, fileUrl: fixture.fileUrl } : track;
    });
    return state;
  } catch {
    return createFixtureState(audioURLs);
  }
}

function saveStoredState(storage, state) {
  if (!storage) return;
  try {
    storage.setItem(BROWSER_STATE_KEY, JSON.stringify({
      runtimeVersion: BROWSER_RUNTIME_VERSION,
      state,
    }));
  } catch {
    // Browser storage is a convenience for UI work, not renderer authority.
  }
}

function listenerRegistry() {
  const listeners = new Map();
  const subscribe = (event, callback) => {
    if (typeof callback !== "function") return () => {};
    const set = listeners.get(event) || new Set();
    set.add(callback);
    listeners.set(event, set);
    return () => set.delete(callback);
  };
  const emit = (event, value) => {
    for (const callback of listeners.get(event) || []) {
      try { callback(value); } catch { /* A test listener must not break the renderer. */ }
    }
  };
  return { subscribe, emit };
}

function browserWindow() {
  try {
    return typeof globalThis === "object" && globalThis.window ? globalThis.window : null;
  } catch {
    return null;
  }
}

function requestBrowserReload(currentWindow = browserWindow()) {
  if (!currentWindow || typeof currentWindow.location?.reload !== "function") return false;
  try {
    currentWindow.location.reload();
    return true;
  } catch {
    return false;
  }
}

function dispatchBrowserStateReset(currentWindow, state) {
  if (!currentWindow || typeof currentWindow.dispatchEvent !== "function") return;
  try {
    const EventConstructor = currentWindow.CustomEvent
      || (typeof globalThis === "object" ? globalThis.CustomEvent : null);
    if (typeof EventConstructor !== "function") return;
    currentWindow.dispatchEvent(new EventConstructor(BROWSER_STATE_RESET_EVENT, {
      detail: clone(state),
    }));
  } catch {
    // Browser automation can still use the explicit reload helper when a
    // restricted document refuses to construct or dispatch custom events.
  }
}

export function createBrowserResonanceAPI(options = {}) {
  let storage;
  try {
    storage = options && Object.prototype.hasOwnProperty.call(options, "storage")
      ? options.storage
      : defaultBrowserStorage();
  } catch {
    storage = null;
  }
  const browserStorage = safeStorage(storage);
  const audioURLs = fixtureAudioURLs();
  let state = loadStoredState(browserStorage, audioURLs);
  const events = listenerRegistry();
  let closeHandler = null;

  const persist = (nextState) => {
    state = clone(nextState || state);
    saveStoredState(browserStorage, state);
    return clone(state);
  };

  const api = {
    loadLibrary: async () => ({ state: clone(state) }),
    saveLibrary: async (nextState) => { persist(nextState); return true; },
    refreshLibraryMetadata: async () => [],
    videoFrames: async () => [],
    onPrepareToClose: (callback) => { closeHandler = callback; return () => { closeHandler = null; }; },
    readyToClose: () => undefined,
    updateAppPreferences: async (preferences) => {
      state.appPreferences = { ...state.appPreferences, ...(preferences || {}) };
      saveStoredState(browserStorage, state);
      return true;
    },
    updateDiscordPresence: async () => ({ state: "disabled", message: "Rich Presence is unavailable in a browser preview.", applicationConfigured: false }),
    getDiscordPresenceStatus: async () => ({ state: "disabled", message: "Rich Presence is unavailable in a browser preview.", applicationConfigured: false }),
    onDiscordPresenceStatus: (callback) => events.subscribe("discordPresenceStatus", callback),
    importAudio: async () => [],
    loadProfilePicture: async () => null,
    chooseProfilePicture: async () => null,
    removeProfilePicture: async () => true,
    localImportCapabilities: async () => ({ enabled: true, browser: true, providers: ["youtube", "spotify", "soundcloud"] }),
    fetchLocalImportArtwork: async () => null,
    previewLocalImport: async () => ({ ok: false, error: { message: "Preview playback is unavailable in a browser fixture." } }),
    cancelLocalImportPreview: async () => true,
    resolveLocalImport: async () => ({ ok: false, error: { stage: "resolving_metadata", message: "Web import is unavailable in a browser fixture." } }),
    startLocalImport: async () => ({ ok: false, error: { stage: "downloading", message: "Web import is unavailable in a browser fixture." } }),
    startExternalImport: async () => ({ ok: false, error: { stage: "downloading", message: "Web import is unavailable in a browser fixture." } }),
    cancelLocalImport: async () => true,
    uploadLocalImport: async () => ({ ok: false, error: { message: "Uploads are unavailable in a browser fixture." } }),
    onLocalImportProgress: (callback) => events.subscribe("localImportProgress", callback),
    deleteAudio: async () => true,
    revealAudio: async () => false,
    storageSummary: async () => {
      const localBytes = state.tracks
        .filter((track) => track?.available !== false && track?.storageLocation !== "server-cache")
        .reduce((total, track) => total + Math.max(0, Number(track.size) || 0), 0);
      const remoteBytes = state.tracks
        .filter((track) => track?.available !== false && track?.storageLocation === "server-cache")
        .reduce((total, track) => total + Math.max(0, Number(track.size) || 0), 0);
      let availableBytes = DEFAULT_CAPACITY_BYTES - localBytes - remoteBytes;
      let capacityBytes = DEFAULT_CAPACITY_BYTES;
      try {
        const estimate = await globalThis.navigator?.storage?.estimate?.();
        if (Number.isFinite(estimate?.quota) && estimate.quota > 0) capacityBytes = estimate.quota;
        if (Number.isFinite(estimate?.quota) && Number.isFinite(estimate?.usage)) {
          availableBytes = Math.max(0, estimate.quota - estimate.usage);
        }
      } catch { /* Use deterministic fallback. */ }
      return { localBytes, remoteBytes, availableBytes: Math.max(0, availableBytes), capacityBytes };
    },
    fetchCatalog: async () => ({ songs: [], count: 0 }),
    resolveServerSourceMetadata: async () => null,
    fetchClientConfig: async () => ({ config: clone(SAFE_CLIENT_CONFIG), source: "browser" }),
    createServerStream: async () => null,
    releaseServerStream: async () => true,
    createListenAlong: async () => ({ ok: false, error: { message: "Listen Along needs the Electron server bridge." } }),
    joinListenAlong: async () => ({ ok: false, error: { message: "Listen Along needs the Electron server bridge." } }),
    updateListenAlong: async () => ({ ok: false, error: { message: "Listen Along needs the Electron server bridge." } }),
    leaveListenAlong: async () => true,
    copyListenAlongCode: async (code) => {
      try { await globalThis.navigator?.clipboard?.writeText?.(String(code || "")); } catch { /* Clipboard permissions are optional. */ }
      return true;
    },
    createListenAlongSource: async () => null,
    releaseListenAlongSource: async () => true,
    onListenAlongEvent: (callback) => events.subscribe("listenAlongEvent", callback),
    onListenAlongStatus: (callback) => events.subscribe("listenAlongStatus", callback),
    fetchServerArtwork: async () => null,
    fetchProfiles: async () => ({ profiles: [{ id: "default", name: "Default", is_default: true }] }),
    createProfile: async () => ({ profile: { id: "browser", name: "Browser profile", is_default: false } }),
    fetchPlaylists: async () => ({ revision: state.playlistRevision || 0, playlists: [], liked_song_ids: [], clip_ranges: [] }),
    putPlaylists: async () => ({ revision: state.playlistRevision || 0, playlists: [], liked_song_ids: [], clip_ranges: [] }),
    postListeningHistory: async () => ({ accepted: 0 }),
    fetchListeningHistory: async () => ({ entries: [] }),
    syncServer: async () => ({ catalog: { songs: [], count: 0 }, downloaded: [], failed: [], results: [], cancelled: false }),
    uploadServer: async () => ({ selectionCancelled: true, uploaded: 0, results: [], failed: [] }),
    importServerSource: async () => ({ ok: false, error: { message: "Server imports are unavailable in a browser fixture." } }),
    discardServerUploadRetries: async () => true,
    cancelServerTransfer: async () => true,
    deleteServerSong: async () => true,
    loadServerCredentials: async () => ({ clientToken: "", adminToken: "" }),
    saveServerCredentials: async () => true,
    loadAccountSession: async () => null,
    signInAccount: async () => ({ ok: false, error: { message: "Account sign-in is unavailable in a browser fixture." } }),
    refreshAccountSession: async () => null,
    signOutAccount: async () => true,
    onAccountSession: (callback) => events.subscribe("accountSession", callback),
    onTransferProgress: (callback) => events.subscribe("transferProgress", callback),
    openAdmin: async () => false,
    checkForUpdates: async () => ({ supported: false }),
    getUpdateStatus: async () => ({ type: "current" }),
    installUpdate: async () => false,
    onUpdateStatus: (callback) => events.subscribe("updateStatus", callback),
  };

  const reset = (options = {}) => {
    state = createFixtureState(audioURLs);
    saveStoredState(browserStorage, state);
    const payload = clone(state);
    events.emit("browserStateReset", payload);
    dispatchBrowserStateReset(browserWindow(), payload);
    // A reload is the deterministic way to make the already-running app.js
    // renderer consume the new state. Callers that need to inspect the event
    // without navigating can pass { reload: false }.
    if (!options || options.reload !== false) {
      // Let browser automation receive the reset result before navigation
      // destroys the current execution context.
      const resetWindow = browserWindow();
      if (resetWindow) setTimeout(() => requestBrowserReload(resetWindow), 0);
    }
    return clone(state);
  };

  return Object.assign(api, {
    browser: true,
    browserRuntimeVersion: BROWSER_RUNTIME_VERSION,
    browserStateResetEvent: BROWSER_STATE_RESET_EVENT,
    getBrowserState: () => clone(state),
    resetBrowserState: reset,
    onBrowserStateReset: (callback) => events.subscribe("browserStateReset", callback),
    reloadBrowserState: requestBrowserReload,
    emitBrowserEvent: events.emit,
    closeBrowserRuntime: async () => {
      if (typeof closeHandler === "function") await closeHandler();
    },
  });
}

if (typeof window !== "undefined" && !window.resonance) {
  const browserAPI = createBrowserResonanceAPI();
  window.resonance = browserAPI;
  // Deliberately public for browser automation and manual UI reset between runs.
  window.__resonanceBrowser = browserAPI;
}
