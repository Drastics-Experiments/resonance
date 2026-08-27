import { createClientUUID, createEmptyState } from "./core.js";

const BROWSER_LIBRARY_KEY = "resonance.browser.library.v2";
const STREAM_ONLY_CONFIG_LIFETIME_MS = 10 * 60 * 1000;

function clone(value) {
  if (typeof structuredClone === "function") return structuredClone(value);
  return JSON.parse(JSON.stringify(value));
}

function safeStorage(candidate) {
  return candidate && typeof candidate.getItem === "function" && typeof candidate.setItem === "function"
    ? candidate
    : null;
}

function defaultStorage() {
  try { return safeStorage(globalThis.localStorage); }
  catch { return null; }
}

function storedJSON(storage, key, fallback) {
  if (!storage) return clone(fallback);
  try {
    const value = JSON.parse(storage.getItem(key));
    return value && typeof value === "object" ? value : clone(fallback);
  } catch {
    return clone(fallback);
  }
}

function saveJSON(storage, key, value) {
  if (!storage) return;
  try { storage.setItem(key, JSON.stringify(value)); }
  catch { /* Private browsing may disable persistent storage. */ }
}

function browserLibrary(storage) {
  const state = { ...createEmptyState(), ...storedJSON(storage, BROWSER_LIBRARY_KEY, createEmptyState()) };
  state.tracks = (Array.isArray(state.tracks) ? state.tracks : [])
    .filter((track) => track?.transientStream !== true)
    .map((track) => {
      const staleObjectURL = typeof track?.fileUrl === "string" && track.fileUrl.startsWith("blob:");
      return staleObjectURL ? { ...track, fileUrl: "", available: false, missing: true } : track;
    });
  return state;
}

function listenerRegistry() {
  const listeners = new Map();
  return {
    subscribe(name, callback) {
      if (typeof callback !== "function") return () => {};
      const group = listeners.get(name) || new Set();
      group.add(callback);
      listeners.set(name, group);
      return () => group.delete(callback);
    },
    emit(name, value) {
      for (const callback of listeners.get(name) || []) {
        try { callback(value); } catch { /* A listener cannot break the runtime. */ }
      }
    },
  };
}

async function responseJSON(response, fallbackMessage) {
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload?.error || payload?.message || `${fallbackMessage} (HTTP ${response.status}).`);
  return payload;
}

function browserStreamOnlyConfig(now = Date.now()) {
  return {
    schema_version: 1,
    revision: 1,
    issued_at: new Date(now - 1_000).toISOString(),
    not_before: new Date(now - 1_000).toISOString(),
    expires_at: new Date(now + STREAM_ONLY_CONFIG_LIFETIME_MS).toISOString(),
    values: {
      "upload.local_file": true,
      "upload.server_source_link": true,
      "upload.reviewed_match": false,
      "upload.external_object": false,
      "download.offline_mode": "stream_only",
      "download.playback_mode": "same_origin_resolver",
      "matcher.mode": "off",
      "storage.read_mode": "r2_only",
      "storage.r2_reclaim": false,
    },
    kill_switches: {
      all_uploads: false,
      link_imports: false,
      offline_downloads: true,
      external_reads: true,
      r2_reclaim: true,
    },
    verified: true,
    source: "browser-runtime",
  };
}

function browserWindow() {
  return typeof window === "undefined" ? null : window;
}

function fileTitle(name) {
  return String(name || "Imported song").replace(/\.[^.]+$/, "").trim() || "Imported song";
}

async function chooseBrowserAudioFiles(currentWindow = browserWindow()) {
  const document = currentWindow?.document;
  if (!document) return [];
  return new Promise((resolve) => {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = "audio/*,video/*";
    input.multiple = true;
    input.hidden = true;
    input.addEventListener("change", () => {
      const tracks = [...(input.files || [])].map((file) => ({
        id: `browser-local:${createClientUUID()}`,
        title: fileTitle(file.name),
        artist: "Unknown Artist",
        album: "Local Files",
        duration: 0,
        size: Number(file.size) || 0,
        filePath: null,
        fileUrl: URL.createObjectURL(file),
        artwork: null,
        artworkURL: null,
        dateAdded: new Date().toISOString(),
        available: true,
        missing: false,
        storageLocation: "local",
        browserLocal: true,
      }));
      input.remove();
      resolve(tracks);
    }, { once: true });
    document.body.append(input);
    input.click();
  });
}

export function createBrowserResonanceAPI(options = {}) {
  const storage = safeStorage(Object.prototype.hasOwnProperty.call(options, "storage") ? options.storage : defaultStorage());
  const currentFetch = options.fetchImpl || globalThis.fetch?.bind(globalThis);
  const currentWindow = options.window || browserWindow();
  const events = listenerRegistry();
  let state = browserLibrary(storage);
  let clerkPromise = null;
  let accountSession = null;
  let clerkUnsubscribe = null;

  const persist = (nextState) => {
    state = clone(nextState || state);
    const durable = clone(state);
    durable.tracks = (durable.tracks || []).filter((track) => track?.transientStream !== true);
    saveJSON(storage, BROWSER_LIBRARY_KEY, durable);
    return clone(state);
  };

  const loadClerk = async () => {
    if (options.clerk) return options.clerk;
    if (clerkPromise) return clerkPromise;
    clerkPromise = (async () => {
      if (!currentWindow?.document || typeof currentFetch !== "function") return null;
      const configuration = await responseJSON(
        await currentFetch("/api/browser/auth/config", { cache: "no-store" }),
        "Account sign-in configuration is unavailable",
      );
      if (!currentWindow.Clerk) {
        await new Promise((resolve, reject) => {
          const script = currentWindow.document.createElement("script");
          script.src = "/api/browser/auth/clerk.js";
          script.async = true;
          script.crossOrigin = "anonymous";
          script.dataset.clerkPublishableKey = configuration.publishable_key;
          script.onload = resolve;
          script.onerror = () => reject(new Error("The account sign-in client could not be loaded."));
          currentWindow.document.head.append(script);
        });
      }
      const clerk = currentWindow.Clerk;
      if (!clerk) throw new Error("The account sign-in client is unavailable.");
      await clerk.load({ publishableKey: configuration.publishable_key });
      clerk.__resonanceTokenTemplate = configuration.token_template;
      return clerk;
    })();
    return clerkPromise;
  };

  const accessToken = async () => {
    const clerk = await loadClerk();
    return clerk?.session?.getToken
      ? clerk.session.getToken({ template: clerk.__resonanceTokenTemplate || "resonance" })
      : null;
  };

  const request = async (path, init = {}, { authenticated = true } = {}) => {
    if (typeof currentFetch !== "function") throw new Error("Browser networking is unavailable.");
    const headers = new Headers(init.headers || {});
    if (authenticated) {
      const token = await accessToken();
      if (!token) throw new Error("Sign in to your Resonance account.");
      headers.set("Authorization", `Bearer ${token}`);
    }
    return currentFetch(path, { ...init, headers, cache: "no-store" });
  };

  const resolveAccountSession = async () => {
    const token = await accessToken();
    if (!token) return null;
    const account = await responseJSON(await request("/api/browser/auth/me"), "Account access was rejected");
    accountSession = {
      accessToken: token,
      expiresAt: Date.now() + 45_000,
      email: account.email,
      role: account.role,
      baseURL: account.base_url || "https://resonance-core.blithe-haven-9710.chatgpt.site",
      accountID: account.id,
      profileID: account.profile_id || account.id,
      displayName: account.display_name || account.email,
      imageURL: account.image_url || null,
      migratedProfileID: account.migrated_profile_id || null,
    };
    return clone(accountSession);
  };

  const publishAccountSession = async () => {
    try { events.emit("accountSession", { session: await resolveAccountSession(), error: null }); }
    catch (error) { events.emit("accountSession", { session: null, error: error?.message || "Account session failed." }); }
  };

  const ensureClerkListener = async () => {
    const clerk = await loadClerk();
    if (!clerk || clerkUnsubscribe || typeof clerk.addListener !== "function") return clerk;
    clerkUnsubscribe = clerk.addListener(() => { void publishAccountSession(); });
    return clerk;
  };

  const profileHeaders = (profileID) => ({ "X-Resonance-Profile": String(profileID || accountSession?.profileID || "default") });
  const jsonRequest = async (path, init, message) => responseJSON(await request(path, init), message);

  const api = {
    runtime: "browser",
    loadLibrary: async () => ({ state: clone(state) }),
    saveLibrary: async (nextState) => { persist(nextState); return true; },
    refreshLibraryMetadata: async () => [],
    videoFrames: async () => [],
    onPrepareToClose: () => () => {},
    readyToClose: () => undefined,
    updateAppPreferences: async (preferences) => {
      state.appPreferences = { ...state.appPreferences, ...(preferences || {}) };
      persist(state);
      return true;
    },
    updateDiscordPresence: async () => ({ state: "disabled", message: "Rich Presence is available in the installed app.", applicationConfigured: false }),
    getDiscordPresenceStatus: async () => ({ state: "disabled", message: "Rich Presence is available in the installed app.", applicationConfigured: false }),
    onDiscordPresenceStatus: (callback) => events.subscribe("discordPresenceStatus", callback),
    importAudio: async () => chooseBrowserAudioFiles(currentWindow),
    loadProfilePicture: async () => null,
    chooseProfilePicture: async () => null,
    removeProfilePicture: async () => true,
    localImportCapabilities: async () => ({ enabled: false, browser: true, providers: [] }),
    fetchLocalImportArtwork: async () => null,
    previewLocalImport: async () => ({ ok: false, error: { message: "Source previews require the installed app." } }),
    cancelLocalImportPreview: async () => true,
    resolveLocalImport: async () => ({ ok: false, error: { message: "Source search requires the installed app." } }),
    startLocalImport: async () => ({ ok: false, error: { message: "Source downloads require the installed app." } }),
    startExternalImport: async () => ({ ok: false, error: { message: "Source downloads require the installed app." } }),
    cancelLocalImport: async () => true,
    uploadLocalImport: async () => ({ ok: false, error: { message: "Upload the song from the installed app." } }),
    onLocalImportProgress: (callback) => events.subscribe("localImportProgress", callback),
    deleteAudio: async () => true,
    revealAudio: async () => false,
    storageSummary: async () => ({ localBytes: 0, remoteBytes: 0, availableBytes: 0, capacityBytes: 0 }),
    fetchCatalog: async ({ profileID } = {}) => jsonRequest("/api/browser/catalog", { headers: profileHeaders(profileID) }, "The server catalog is unavailable"),
    resolveServerSourceMetadata: async () => ({ ok: false, error: { message: "Source metadata lookup requires the installed app." } }),
    fetchClientConfig: async () => ({ config: browserStreamOnlyConfig(), source: "browser-runtime" }),
    createServerStream: async ({ profileID, songID } = {}) => jsonRequest("/api/browser/streams", {
      method: "POST",
      headers: { ...profileHeaders(profileID), "Content-Type": "application/json" },
      body: JSON.stringify({ songID }),
    }, "Streaming could not be started"),
    releaseServerStream: async (streamURL) => {
      const url = new URL(String(streamURL || ""), currentWindow?.location?.href || "http://127.0.0.1/");
      if (url.origin !== currentWindow?.location?.origin || !url.pathname.startsWith("/api/browser/streams/")) return false;
      return (await request(url.pathname, { method: "DELETE" }, { authenticated: false })).ok;
    },
    createListenAlong: async () => ({ ok: false, error: { message: "Listen Along requires the installed app." } }),
    joinListenAlong: async () => ({ ok: false, error: { message: "Listen Along requires the installed app." } }),
    updateListenAlong: async () => false,
    leaveListenAlong: async () => true,
    copyListenAlongCode: async (code) => { await currentWindow?.navigator?.clipboard?.writeText(String(code || "")); return true; },
    createListenAlongSource: async () => null,
    releaseListenAlongSource: async () => true,
    onListenAlongEvent: (callback) => events.subscribe("listenAlongEvent", callback),
    onListenAlongStatus: (callback) => events.subscribe("listenAlongStatus", callback),
    fetchServerArtwork: async ({ profileID, songID } = {}) => {
      const response = await request(`/api/browser/artwork/${encodeURIComponent(songID)}`, { headers: profileHeaders(profileID) });
      if (!response.ok) throw new Error(`Artwork is unavailable (HTTP ${response.status}).`);
      const blob = await response.blob();
      return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(new Error("Artwork could not be decoded."));
        reader.readAsDataURL(blob);
      });
    },
    fetchProfiles: async ({ profileID } = {}) => jsonRequest("/api/browser/profiles", { headers: profileHeaders(profileID) }, "Profiles are unavailable"),
    createProfile: async ({ name, profileID } = {}) => jsonRequest("/api/browser/profiles", {
      method: "POST",
      headers: { ...profileHeaders(profileID), "Content-Type": "application/json" },
      body: JSON.stringify({ name }),
    }, "The profile could not be created"),
    fetchPlaylists: async ({ profileID } = {}) => jsonRequest("/api/browser/playlists", { headers: profileHeaders(profileID) }, "Playlists are unavailable"),
    putPlaylists: async ({ profileID, document } = {}) => {
      const response = await request("/api/browser/playlists", {
        method: "PUT",
        headers: { ...profileHeaders(profileID), "Content-Type": "application/json" },
        body: JSON.stringify(document || {}),
      });
      const payload = await response.json().catch(() => ({}));
      if (![200, 409].includes(response.status)) {
        throw new Error(payload?.error || payload?.message || `Playlists could not be saved (HTTP ${response.status}).`);
      }
      return { status: response.status, document: payload };
    },
    postListeningHistory: async ({ profileID, entries } = {}) => jsonRequest("/api/browser/listening-history", {
      method: "POST",
      headers: { ...profileHeaders(profileID), "Content-Type": "application/json" },
      body: JSON.stringify({ entries: entries || [] }),
    }, "Listening history could not be saved"),
    fetchListeningHistory: async ({ profileID, limit = 2000 } = {}) => jsonRequest(`/api/browser/listening-history?limit=${encodeURIComponent(limit)}`, {
      headers: profileHeaders(profileID),
    }, "Listening history is unavailable"),
    syncServer: async () => ({ catalog: { count: 0, songs: [] }, downloaded: [], failed: [], cancelled: false }),
    uploadServer: async () => ({ uploaded: [], failed: [] }),
    importServerSource: async () => ({ ok: false, error: { message: "Server source imports require the installed app." } }),
    discardServerUploadRetries: async () => true,
    cancelServerTransfer: async () => true,
    deleteServerSong: async ({ profileID, songID } = {}) => jsonRequest(`/api/browser/admin/songs/${encodeURIComponent(songID)}`, {
      method: "DELETE",
      headers: profileHeaders(profileID),
    }, "The server song could not be deleted"),
    loadServerCredentials: async () => ({ clientToken: "", adminToken: "" }),
    saveServerCredentials: async () => true,
    loadAccountSession: async () => {
      await ensureClerkListener();
      return resolveAccountSession();
    },
    signInAccount: async () => {
      const clerk = await ensureClerkListener();
      if (!clerk) throw new Error("Account sign-in is unavailable.");
      if (clerk.session) {
        await publishAccountSession();
        return { started: false, signedIn: true };
      }
      if (typeof clerk.openSignIn !== "function") throw new Error("Account sign-in is unavailable.");
      clerk.openSignIn({});
      return { started: true, provider: "clerk" };
    },
    refreshAccountSession: async () => resolveAccountSession(),
    signOutAccount: async () => {
      const clerk = await loadClerk();
      await clerk?.signOut?.();
      accountSession = null;
      events.emit("accountSession", { session: null, error: null });
      return true;
    },
    onAccountSession: (callback) => events.subscribe("accountSession", callback),
    onTransferProgress: (callback) => events.subscribe("transferProgress", callback),
    openAdmin: async () => false,
    checkForUpdates: async () => ({ supported: false }),
    getUpdateStatus: async () => ({ type: "current" }),
    installUpdate: async () => false,
    onUpdateStatus: (callback) => events.subscribe("updateStatus", callback),
  };

  return api;
}

if (typeof window !== "undefined" && !window.resonance) {
  window.resonance = createBrowserResonanceAPI();
}
