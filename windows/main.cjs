const { app, BrowserWindow, dialog, ipcMain, shell } = require("electron");
const { autoUpdater } = require("electron-updater");
const { createHash, randomUUID } = require("node:crypto");
const { createReadStream } = require("node:fs");
const fs = require("node:fs/promises");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const { readAudioMetadata } = require("./metadata.cjs");
const { SERVER_DOWNLOAD_ATTEMPTS, retryServerDownload } = require("./server-download.cjs");
const { conciseUpdaterError, installDownloadedWindowsUpdate, resolveWindowsUpdateFeed } = require("./updater-feed.cjs");
const { LocalImportError, searchYouTubeAudioSources } = require("./local-import-core.cjs");
const { importFileBackedSource, searchFileBackedSources } = require("./local-debrid.cjs");
const { artworkFileDataURL, fetchArtwork, importConfirmedSource, resolveLocalImportSource } = require("./local-import-platform.cjs");
const { downloadResolvedAudio, resolveYouTubeAudio } = require("./local-youtube.cjs");

function protectDetachedOutput(stream) {
  if (!stream?.on) return;
  stream.on("error", (error) => {
    if (error?.code === "EPIPE" || error?.code === "EIO") return;
    setImmediate(() => { throw error; });
  });
}

// A source Preview may outlive the terminal that launched it. Electron logs
// rejected IPC calls to stderr, so a detached pipe must not turn an ordinary
// connection error into a fatal main-process alert.
protectDetachedOutput(process.stdout);
protectDetachedOutput(process.stderr);

const AUDIO_EXTENSIONS = new Set([".aac", ".aif", ".aiff", ".alac", ".flac", ".m4a", ".m4b", ".mp3", ".ogg", ".opus", ".wav"]);
const SERVER_ARTWORK_TYPES = new Set(["image/avif", "image/gif", "image/jpeg", "image/png", "image/webp"]);
const MAX_SERVER_ARTWORK_BYTES = 8 * 1024 * 1024;
const MAX_LOCAL_IMPORT_UPLOAD_BYTES = 256 * 1024 * 1024;
const MAX_LOCAL_IMPORT_PREVIEW_BYTES = 32 * 1024 * 1024;

let mainWindow;
let applicationQuitRequested = false;
const activeServerTransfers = new Map();
const activeLocalImports = new Map();
const activeLocalImportPreviews = new Map();
const cachedLocalImportPreviews = new Map();
const pendingExternalImports = new Map();
let librarySaveQueue = Promise.resolve();

async function atomicWriteFile(destination, data, options = "utf8") {
  const temporary = `${destination}.${process.pid}.${randomUUID()}.tmp`;
  try {
    await fs.writeFile(temporary, data, options);
    await fs.rename(temporary, destination);
  } catch (error) {
    await fs.rm(temporary, { force: true }).catch(() => undefined);
    throw error;
  }
}

async function fileSHA256(filePath) {
  return new Promise((resolve, reject) => {
    const hash = createHash("sha256");
    const stream = createReadStream(filePath);
    stream.on("data", (chunk) => hash.update(chunk));
    stream.on("error", reject);
    stream.on("end", () => resolve(hash.digest("hex")));
  });
}

async function writeResponseToFile(response, destination, { signal, expectedSize } = {}) {
  const reader = response.body?.getReader();
  if (!reader) throw new Error("The server returned an empty download.");
  const handle = await fs.open(destination, "wx");
  const hash = createHash("sha256");
  let total = 0;
  try {
    while (true) {
      signal?.throwIfAborted();
      const { done, value } = await reader.read();
      if (done) break;
      const buffer = Buffer.from(value);
      hash.update(buffer);
      let offset = 0;
      while (offset < buffer.length) {
        const { bytesWritten } = await handle.write(buffer, offset, buffer.length - offset);
        if (!bytesWritten) throw new Error("The downloaded file could not be written.");
        offset += bytesWritten;
      }
      total += buffer.length;
    }
    signal?.throwIfAborted();
    if (Number.isFinite(expectedSize) && expectedSize >= 0 && total !== expectedSize) {
      throw new Error("The downloaded file was incomplete.");
    }
    return { size: total, sha256: hash.digest("hex") };
  } catch (error) {
    await reader.cancel(error).catch(() => undefined);
    throw error;
  } finally {
    reader.releaseLock();
    await handle.close();
  }
}

function usesPreviewCredentialStore() {
  return process.platform === "darwin" && !app.isPackaged;
}

function previewCredentialStorePath() {
  return path.join(app.getPath("appData"), "Liked Songs", "server-credentials.json");
}

async function readPreviewCredentials() {
  try {
    const payload = JSON.parse(await fs.readFile(previewCredentialStorePath(), "utf8"));
    return {
      clientToken: String(payload?.clientToken || ""),
      adminToken: String(payload?.adminToken || ""),
    };
  } catch {
    return { clientToken: "", adminToken: "" };
  }
}

async function writePreviewCredentials(credentials) {
  const destination = previewCredentialStorePath();
  const directory = path.dirname(destination);
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  await fs.chmod(directory, 0o700);
  const temporary = `${destination}.${process.pid}.${randomUUID()}.tmp`;
  try {
    await fs.writeFile(temporary, JSON.stringify(credentials), { encoding: "utf8", mode: 0o600 });
    await fs.chmod(temporary, 0o600);
    await fs.rename(temporary, destination);
    await fs.chmod(destination, 0o600);
  } catch (error) {
    await fs.rm(temporary, { force: true }).catch(() => undefined);
    throw error;
  }
}

function encryptedCredentialStorage() {
  return require("electron").safeStorage;
}

function localImportEnabled() {
  return process.env.RESONANCE_LOCAL_DEVICE_IMPORT !== "0";
}

function beginLocalImport(event) {
  const senderID = event.sender.id;
  activeLocalImports.get(senderID)?.abort();
  const controller = new AbortController();
  activeLocalImports.set(senderID, controller);
  return controller;
}

function finishLocalImport(event, controller) {
  if (activeLocalImports.get(event.sender.id) === controller) activeLocalImports.delete(event.sender.id);
}

async function clearLocalImportPreview(senderID) {
  const active = activeLocalImportPreviews.get(senderID);
  if (active) {
    active.controller.abort(new DOMException("Preview stopped", "AbortError"));
    activeLocalImportPreviews.delete(senderID);
  }
  const cached = cachedLocalImportPreviews.get(senderID);
  cachedLocalImportPreviews.delete(senderID);
  const directories = new Set([active?.directory, cached?.directory].filter(Boolean));
  await Promise.all([...directories].map((directory) =>
    fs.rm(directory, { recursive: true, force: true }).catch(() => undefined)));
}

function localImportFailure(error, fallbackStage) {
  if (error?.name === "AbortError") {
    return { stage: fallbackStage, code: "CANCELLED", message: "Import cancelled." };
  }
  if (error instanceof LocalImportError) {
    return { stage: error.stage, code: error.code, message: error.message, retryAfter: error.retryAfter || null };
  }
  return {
    stage: fallbackStage,
    code: "LOCAL_IMPORT_FAILED",
    message: error?.message || "Resonance could not complete the local import.",
  };
}

function beginServerTransfer(event) {
  const senderID = event.sender.id;
  activeServerTransfers.get(senderID)?.abort();
  const controller = new AbortController();
  activeServerTransfers.set(senderID, controller);
  return controller;
}

function finishServerTransfer(event, controller) {
  if (activeServerTransfers.get(event.sender.id) === controller) activeServerTransfers.delete(event.sender.id);
}

// electron-updater logs to console by default. Packaged GUI launches may inherit
// a short-lived stdout pipe, so a delayed update check can otherwise crash with
// EPIPE after that parent process exits. Status is surfaced through IPC instead.
autoUpdater.logger = null;
autoUpdater.autoDownload = true;
autoUpdater.autoInstallOnAppQuit = true;

function publishUpdateStatus(type, details = {}) {
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send("update:status", { type, ...details });
}

autoUpdater.on("checking-for-update", () => publishUpdateStatus("checking"));
autoUpdater.on("update-available", (information) => publishUpdateStatus("available", { version: information.version }));
autoUpdater.on("update-not-available", () => publishUpdateStatus("current"));
autoUpdater.on("download-progress", (progress) => publishUpdateStatus("downloading", { percent: Math.round(progress.percent || 0) }));
autoUpdater.on("update-downloaded", (information) => publishUpdateStatus("ready", { version: information.version }));
autoUpdater.on("error", (error) => publishUpdateStatus("error", { message: conciseUpdaterError(error) }));

async function checkForWindowsUpdates() {
  const { feedURL } = await resolveWindowsUpdateFeed();
  autoUpdater.setFeedURL({ provider: "generic", url: feedURL });
  return autoUpdater.checkForUpdates();
}

function applicationPaths() {
  const root = app.getPath("userData");
  return {
    state: path.join(root, "library.json"),
    credentials: path.join(root, "server-credentials.bin"),
    local: path.join(root, "LocalMusic"),
    remote: path.join(root, "ServerCache"),
  };
}

function safeFilename(value) {
  return path.basename(String(value || "")).replace(/[<>:"/\\|?*\u0000-\u001f]/g, "-").trim();
}

function safeListeningHistory(value) {
  return (Array.isArray(value) ? value : [])
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
}

async function ensureDirectories() {
  const paths = applicationPaths();
  await Promise.all([fs.mkdir(paths.local, { recursive: true }), fs.mkdir(paths.remote, { recursive: true })]);
  return paths;
}

async function cleanupLocalImportTemporaryFiles() {
  const temporaryRoot = app.getPath("temp");
  let entries = [];
  try {
    entries = await fs.readdir(temporaryRoot, { withFileTypes: true });
  } catch {
    return;
  }
  await Promise.all(entries
    .filter((entry) => entry.isDirectory() && entry.name.startsWith("resonance-local-import-"))
    .map((entry) => fs.rm(path.join(temporaryRoot, entry.name), { recursive: true, force: true }).catch(() => undefined)));
}

async function uniqueDestination(directory, preferred) {
  const clean = safeFilename(preferred) || `Track-${Date.now()}.mp3`;
  const extension = path.extname(clean);
  const base = path.basename(clean, extension);
  let candidate = path.join(directory, clean);
  let counter = 2;
  while (true) {
    try {
      await fs.access(candidate);
      candidate = path.join(directory, `${base} ${counter}${extension}`);
      counter += 1;
    } catch {
      return candidate;
    }
  }
}

function publicTrack(filePath, details = {}) {
  return {
    id: details.id || randomUUID(),
    title: details.title || path.basename(filePath, path.extname(filePath)),
    artist: details.artist || "Local file",
    album: details.album || "Unknown Album",
    duration: Number(details.duration) || 0,
    artwork: details.artwork || null,
    size: Number(details.size) || 0,
    filePath,
    fileUrl: pathToFileURL(filePath).href,
    remoteID: details.remoteID || null,
    sourceServer: details.sourceServer || null,
    syncProfileID: details.syncProfileID || null,
    remoteModified: details.remoteModified || null,
    sourceURL: details.sourceURL || null,
    sourceSha256: details.sourceSha256 || null,
    contentSha256: details.contentSha256 || null,
    dateAdded: details.dateAdded || new Date().toISOString(),
  };
}

async function enrichedTrack(filePath, details = {}) {
  const metadata = await readAudioMetadata(filePath);
  return publicTrack(filePath, {
    ...details,
    title: metadata.title || details.title,
    artist: metadata.artist || details.artist,
    album: metadata.album || details.album,
    duration: metadata.duration || details.duration,
    artwork: metadata.artwork || details.artwork,
  });
}

function normalizeBaseURL(value) {
  const url = new URL(String(value || "").trim());
  if (url.protocol !== "https:" && url.protocol !== "http:") throw new Error("Enter a complete http:// or https:// server URL.");
  url.pathname = url.pathname.replace(/\/+$/, "") + "/";
  return url;
}

function matchesServerOrigin(value, expectedOrigin) {
  if (!value) return true;
  try {
    return new URL(value).origin === expectedOrigin;
  } catch {
    return false;
  }
}

async function authenticatedJSON(url, token, signal) {
  const response = await fetch(url, { headers: { Authorization: `Bearer ${token}` }, signal });
  if (!response.ok) throw await serverResponseError(response);
  return response.json();
}

async function serverResponseError(response) {
  let message = "";
  let body = "";
  const contentType = response.headers.get("content-type")?.toLowerCase() || "";
  try { body = await response.text(); } catch { /* no response body */ }
  if (contentType.includes("json")) {
    try {
      const payload = JSON.parse(body);
      message = typeof payload?.error === "string" ? payload.error : "";
    } catch {
      // Invalid JSON should not replace the useful HTTP status.
    }
  } else if (!contentType.includes("html")) {
    message = body.trim().slice(0, 500);
  }
  if (!message && response.status === 404) {
    message = "The configured server URL is not serving this Resonance API route.";
  }
  return new Error(`Server returned HTTP ${response.status}${message ? `: ${message}` : ""}`);
}

async function responseBytesWithLimit(response, limit) {
  const reader = response.body?.getReader();
  if (!reader) return Buffer.alloc(0);
  const chunks = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel();
      throw new Error("Server artwork is too large.");
    }
    chunks.push(Buffer.from(value));
  }
  return Buffer.concat(chunks, total);
}

function createWindow() {
  const window = new BrowserWindow({
    width: 1360,
    height: 850,
    minWidth: 980,
    minHeight: 650,
    backgroundColor: "#07101c",
    title: "Resonance",
    icon: path.join(__dirname, "resonance.ico"),
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  mainWindow = window;
  window.resonanceCloseReady = false;
  window.resonanceCloseRequested = false;
  window.resonanceCloseTimer = null;
  window.on("close", (event) => {
    if (window.resonanceCloseReady || window.isDestroyed()) return;
    event.preventDefault();
    if (window.resonanceCloseRequested) return;
    window.resonanceCloseRequested = true;
    window.webContents.send("app:prepare-close");
    window.resonanceCloseTimer = setTimeout(() => {
      window.resonanceCloseReady = true;
      if (applicationQuitRequested) app.quit();
      else if (!window.isDestroyed()) window.close();
    }, 3000);
    window.resonanceCloseTimer.unref?.();
  });
  window.on("closed", () => {
    if (window.resonanceCloseTimer) clearTimeout(window.resonanceCloseTimer);
    if (mainWindow === window) mainWindow = null;
  });
  window.loadFile(path.join(__dirname, "ui", "index.html"));
}

ipcMain.on("app:close-ready", (event) => {
  const window = BrowserWindow.fromWebContents(event.sender);
  if (!window || window.isDestroyed() || !window.resonanceCloseRequested) return;
  window.resonanceCloseReady = true;
  if (window.resonanceCloseTimer) clearTimeout(window.resonanceCloseTimer);
  if (applicationQuitRequested) app.quit();
  else window.close();
});

app.on("before-quit", () => { applicationQuitRequested = true; });

const hasSingleInstanceLock = app.requestSingleInstanceLock();
if (!hasSingleInstanceLock) app.quit();

app.on("second-instance", () => {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.show();
  mainWindow.focus();
});

app.whenReady().then(async () => {
  if (!hasSingleInstanceLock) return;
  await cleanupLocalImportTemporaryFiles();
  await ensureDirectories();
  createWindow();
  if (app.isPackaged) setTimeout(() => checkForWindowsUpdates().catch(() => {}), 10000);
  app.on("activate", () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});

app.on("window-all-closed", () => { if (process.platform !== "darwin") app.quit(); });

ipcMain.handle("update:check", async () => {
  if (!app.isPackaged) return { supported: false };
  await checkForWindowsUpdates();
  return { supported: true };
});

ipcMain.handle("update:install", () => {
  if (!app.isPackaged) return false;
  // The assisted NSIS UI is useful for a first install, but an update already
  // knows the existing install directory. Apply it silently and relaunch the
  // app so upgrading never sends the user back through setup.
  return installDownloadedWindowsUpdate(autoUpdater);
});

ipcMain.handle("library:load", async () => {
  const { state } = await ensureDirectories();
  try {
    const stored = JSON.parse(await fs.readFile(state, "utf8"));
    const localUploadSizes = new Set((stored.tracks || [])
      .filter((track) => !track?.remoteID && track?.contentSha256 && Number.isFinite(Number(track?.size)))
      .map((track) => Number(track.size)));
    const tracks = await Promise.all((stored.tracks || []).filter((track) => track.filePath).map(async (track) => {
      try {
        const information = await fs.stat(track.filePath);
        if (!information.isFile()) return null;
        const contentSha256 = track.contentSha256
          || (track.remoteID && localUploadSizes.has(information.size) ? await fileSHA256(track.filePath) : null);
        return enrichedTrack(track.filePath, { ...track, size: information.size, contentSha256 });
      } catch {
        return null;
      }
    }));
    stored.tracks = tracks.filter(Boolean);
    await atomicWriteFile(state, JSON.stringify({
      ...stored,
      tracks: stored.tracks.map(({ fileUrl, ...track }) => track),
    }, null, 2), "utf8");
    return { state: stored, warning: null };
  } catch (error) {
    if (error?.code === "ENOENT") return { state: null, warning: null };
    const backup = `${state}.corrupt-${Date.now()}`;
    let warning = "Resonance could not read your saved library. A new empty library was opened.";
    try {
      await fs.copyFile(state, backup);
      warning += ` The unreadable file was preserved as ${path.basename(backup)}.`;
    } catch { /* the original read error remains the useful failure */ }
    return { state: null, warning };
  }
});

ipcMain.handle("library:save", async (_event, state) => {
  const paths = await ensureDirectories();
  const safeState = {
    tracks: Array.isArray(state.tracks) ? state.tracks.map(({ fileUrl, ...track }) => track) : [],
    playlists: Array.isArray(state.playlists) ? state.playlists : [],
    favorites: Array.isArray(state.favorites) ? state.favorites : [],
    serverURL: typeof state.serverURL === "string" ? state.serverURL : "",
    volume: Number.isFinite(state.volume) ? state.volume : 0.78,
    playbackRate: Number.isFinite(state.playbackRate) ? state.playbackRate : 1,
    shuffle: Boolean(state.shuffle),
    repeat: Boolean(state.repeat),
    currentTrackID: state.currentTrackID || null,
    position: Number.isFinite(state.position) ? state.position : 0,
    playbackQueueIDs: Array.isArray(state.playbackQueueIDs) ? state.playbackQueueIDs : [],
    playbackPlaylistID: typeof state.playbackPlaylistID === "string" ? state.playbackPlaylistID : null,
    playlistRevision: Number.isInteger(state.playlistRevision) && state.playlistRevision >= 0 ? state.playlistRevision : 0,
    knownRemotePlaylistIDs: Array.isArray(state.knownRemotePlaylistIDs) ? state.knownRemotePlaylistIDs : [],
    dirtyPlaylistIDs: Array.isArray(state.dirtyPlaylistIDs) ? state.dirtyPlaylistIDs : [],
    deletedPlaylistIDs: Array.isArray(state.deletedPlaylistIDs) ? state.deletedPlaylistIDs : [],
    playlistSyncServerURL: typeof state.playlistSyncServerURL === "string" ? state.playlistSyncServerURL : null,
    syncProfileID: typeof state.syncProfileID === "string" && state.syncProfileID ? state.syncProfileID : "default",
    syncProfiles: Array.isArray(state.syncProfiles) ? state.syncProfiles : [],
    profileStates: state.profileStates && typeof state.profileStates === "object" ? state.profileStates : {},
    remoteLikedSongIDs: Array.isArray(state.remoteLikedSongIDs) ? state.remoteLikedSongIDs : [],
    dirtyRemoteLikeSongIDs: Array.isArray(state.dirtyRemoteLikeSongIDs) ? state.dirtyRemoteLikeSongIDs : [],
    likesDirty: Boolean(state.likesDirty),
    listeningHistory: safeListeningHistory(state.listeningHistory),
  };
  const save = librarySaveQueue
    .catch(() => {})
    .then(() => atomicWriteFile(paths.state, JSON.stringify(safeState, null, 2), "utf8"));
  librarySaveQueue = save;
  await save;
  return true;
});

ipcMain.handle("server:credentials:load", async () => {
  if (usesPreviewCredentialStore()) return readPreviewCredentials();
  const { credentials } = await ensureDirectories();
  const safeStorage = encryptedCredentialStorage();
  if (!safeStorage.isEncryptionAvailable()) return { clientToken: "", adminToken: "" };
  try {
    const encrypted = await fs.readFile(credentials);
    return JSON.parse(safeStorage.decryptString(encrypted));
  } catch {
    return { clientToken: "", adminToken: "" };
  }
});

ipcMain.handle("server:credentials:save", async (_event, value) => {
  const credentialsValue = {
    clientToken: String(value.clientToken || ""),
    adminToken: String(value.adminToken || ""),
  };
  if (usesPreviewCredentialStore()) {
    await writePreviewCredentials(credentialsValue);
    return true;
  }
  const safeStorage = encryptedCredentialStorage();
  if (!safeStorage.isEncryptionAvailable()) throw new Error("Windows credential encryption is unavailable.");
  const { credentials } = await ensureDirectories();
  const payload = JSON.stringify(credentialsValue);
  await fs.writeFile(credentials, safeStorage.encryptString(payload));
  return true;
});

ipcMain.handle("library:import", async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    title: "Import audio",
    properties: ["openFile", "multiSelections"],
    filters: [{ name: "Audio", extensions: [...AUDIO_EXTENSIONS].map((item) => item.slice(1)) }],
  });
  if (result.canceled) return [];
  const paths = await ensureDirectories();
  const tracks = [];
  for (const source of result.filePaths) {
    const destination = await uniqueDestination(paths.local, path.basename(source));
    await fs.copyFile(source, destination);
    const information = await fs.stat(destination);
    tracks.push(await enrichedTrack(destination, { size: information.size }));
  }
  return tracks;
});

ipcMain.handle("local-import:capabilities", () => ({
  enabled: localImportEnabled(),
  sources: ["spotify", "youtube", "youtube_playlists", "youtube_music", "debrid_vault", "torbox"],
  outputFormats: { audio: "m4a", video: "mp4" },
}));

ipcMain.handle("local-import:artwork", async (_event, { url } = {}) => {
  if (!localImportEnabled() || typeof url !== "string" || url.length > 2_048) return null;
  const temporary = await fs.mkdtemp(path.join(app.getPath("temp"), "resonance-local-import-artwork-"));
  try {
    const artworkPath = await fetchArtwork(url, temporary, AbortSignal.timeout(15_000));
    return await artworkFileDataURL(artworkPath);
  } catch {
    return null;
  } finally {
    await fs.rm(temporary, { recursive: true, force: true }).catch(() => undefined);
  }
});

ipcMain.handle("local-import:preview", async (event, { sourceURL } = {}) => {
  if (!localImportEnabled()) {
    return { ok: false, error: { stage: "previewing", code: "FEATURE_DISABLED", message: "Source previews are disabled in this build." } };
  }
  const senderID = event.sender.id;
  const source = String(sourceURL || "");
  const cached = cachedLocalImportPreviews.get(senderID);
  if (cached?.sourceURL === source) {
    try {
      await fs.access(cached.filePath);
      return { ok: true, result: { fileURL: pathToFileURL(cached.filePath).href, durationSeconds: cached.durationSeconds } };
    } catch {
      cachedLocalImportPreviews.delete(senderID);
    }
  }
  await clearLocalImportPreview(senderID);
  const controller = new AbortController();
  const directory = await fs.mkdtemp(path.join(app.getPath("temp"), "resonance-local-import-preview-"));
  const filePath = path.join(directory, "preview.m4a");
  const operation = { controller, directory };
  activeLocalImportPreviews.set(senderID, operation);
  try {
    const resolved = await resolveYouTubeAudio(source, controller.signal);
    if (resolved.contentLength > MAX_LOCAL_IMPORT_PREVIEW_BYTES) {
      throw new LocalImportError("previewing", "PREVIEW_TOO_LARGE", "This source is too large to preview. You can still select and import it.");
    }
    await downloadResolvedAudio(resolved, filePath, controller.signal);
    controller.signal.throwIfAborted();
    const value = { sourceURL: source, filePath, directory, durationSeconds: Math.min(30, resolved.durationSeconds || 30) };
    cachedLocalImportPreviews.set(senderID, value);
    return { ok: true, result: { fileURL: pathToFileURL(filePath).href, durationSeconds: value.durationSeconds } };
  } catch (error) {
    if (error?.name === "AbortError") {
      return { ok: false, error: { stage: "previewing", code: "CANCELLED", message: "Preview stopped." } };
    }
    return { ok: false, error: localImportFailure(error, "previewing") };
  } finally {
    if (activeLocalImportPreviews.get(senderID) === operation) activeLocalImportPreviews.delete(senderID);
    if (cachedLocalImportPreviews.get(senderID)?.directory !== directory) {
      await fs.rm(directory, { recursive: true, force: true }).catch(() => undefined);
    }
  }
});

ipcMain.handle("local-import:preview:cancel", async (event) => {
  await clearLocalImportPreview(event.sender.id);
  return true;
});

ipcMain.handle("local-import:resolve", async (event, { source, mediaKind, baseURL, adminToken, profileID } = {}) => {
  if (!localImportEnabled()) {
    return {
      ok: false,
      error: { stage: "idle", code: "FEATURE_DISABLED", message: "Local link import is disabled in this build." },
    };
  }
  const controller = beginLocalImport(event);
  const publish = (value) => {
    if (!event.sender.isDestroyed()) event.sender.send("local-import:progress", value);
  };
  try {
    pendingExternalImports.delete(event.sender.id);
    const sourceWarnings = [];
    const result = await resolveLocalImportSource(String(source || ""), controller.signal, publish, {
      searchYouTubeAudioSources: async (track, signal) => {
        const [youtubeResult, externalResult] = await Promise.allSettled([
          searchYouTubeAudioSources(track, signal),
          searchFileBackedSources(track, { baseURL, adminToken, profileID }, signal),
        ]);
        const candidates = [];
        if (youtubeResult.status === "fulfilled") candidates.push(...youtubeResult.value);
        else if (youtubeResult.reason?.name === "AbortError") throw youtubeResult.reason;
        else sourceWarnings.push(youtubeResult.reason?.message || "YouTube source search failed.");
        if (externalResult.status === "fulfilled") candidates.push(...externalResult.value);
        else if (externalResult.reason?.name === "AbortError") throw externalResult.reason;
        else sourceWarnings.push(externalResult.reason?.message || "File-backed source search failed.");
        if (!candidates.length && youtubeResult.status === "rejected" && externalResult.status === "rejected") {
          throw youtubeResult.reason || externalResult.reason;
        }
        return candidates;
      },
    }, { mediaKind });
    result.sourceWarnings = [...new Set(sourceWarnings)].slice(0, 2);
    publish({ stage: "awaiting_selection", track: result.track, candidates: result.candidates });
    return { ok: true, result };
  } catch (error) {
    return { ok: false, error: localImportFailure(error, "resolving_metadata") };
  } finally {
    finishLocalImport(event, controller);
  }
});

ipcMain.handle("local-import:start-external", async (event, value = {}) => {
  if (!localImportEnabled()) {
    return {
      ok: false,
      error: { stage: "idle", code: "FEATURE_DISABLED", message: "Local link import is disabled in this build." },
    };
  }
  const controller = beginLocalImport(event);
  const publish = (progress) => {
    if (!event.sender.isDestroyed()) event.sender.send("local-import:progress", progress);
  };
  try {
    const paths = await ensureDirectories();
    const pending = pendingExternalImports.get(event.sender.id) || null;
    const fileID = Number(value.fileID);
    if (value.resumeSelection && (!pending || !Number.isSafeInteger(fileID))) {
      throw new LocalImportError("awaiting_selection", "EXTERNAL_SELECTION_EXPIRED", "Choose the file-backed release again before selecting its audio file.");
    }
    const result = await importFileBackedSource({
      baseURL: value.baseURL,
      adminToken: value.adminToken,
      profileID: value.profileID,
      sourceURL: value.sourceURL,
      resume: value.resumeSelection ? pending : null,
      fileID: value.resumeSelection ? fileID : null,
      metadata: value.metadata,
      existing: Array.isArray(value.existing) ? value.existing : [],
      destinationDirectory: paths.local,
    }, controller.signal, publish);
    if (result.kind === "selection_required") {
      pendingExternalImports.set(event.sender.id, result.resume);
      publish({ stage: "awaiting_selection", provider: "torbox", files: result.files });
      return { ok: true, result: { kind: "selection_required", files: result.files, serverBacked: true } };
    }
    pendingExternalImports.delete(event.sender.id);
    if (result.kind === "duplicate") {
      publish({ stage: "local_complete", duplicate: true, trackID: result.track.id, serverBacked: true });
      return { ok: true, result: { kind: "duplicate", trackID: result.track.id, serverBacked: true, remoteSong: result.remoteSong } };
    }
    const track = await enrichedTrack(result.filePath, {
      title: result.metadata.title,
      artist: result.metadata.artist,
      album: result.metadata.album,
      artwork: result.artwork || null,
      size: result.size,
      sourceURL: result.sourceURL,
      sourceSha256: result.sourceSha256,
      contentSha256: result.contentSha256,
    });
    publish({ stage: "local_complete", song: track, serverBacked: true });
    return { ok: true, result: { kind: "created", track, serverBacked: true, remoteSong: result.remoteSong } };
  } catch (error) {
    pendingExternalImports.delete(event.sender.id);
    return { ok: false, error: localImportFailure(error, "preparing_external") };
  } finally {
    finishLocalImport(event, controller);
  }
});

ipcMain.handle("local-import:start", async (event, value = {}) => {
  if (!localImportEnabled()) {
    return {
      ok: false,
      error: { stage: "idle", code: "FEATURE_DISABLED", message: "Local link import is disabled in this build." },
    };
  }
  const controller = beginLocalImport(event);
  const publish = (progress) => {
    if (!event.sender.isDestroyed()) event.sender.send("local-import:progress", progress);
  };
  try {
    const paths = await ensureDirectories();
    const result = await importConfirmedSource({
      sourceURL: String(value.sourceURL || ""),
      mediaKind: value.mediaKind,
      metadata: value.metadata,
      existing: Array.isArray(value.existing) ? value.existing : [],
      destinationDirectory: paths.local,
      temporaryRoot: app.getPath("temp"),
    }, controller.signal, publish);
    if (result.kind === "duplicate") {
      publish({ stage: "local_complete", duplicate: true, trackID: result.track.id });
      return { ok: true, result: { kind: "duplicate", trackID: result.track.id } };
    }
    const track = await enrichedTrack(result.filePath, {
      title: result.metadata.title,
      artist: result.metadata.artist,
      album: result.metadata.album,
      artwork: result.artwork || null,
      size: result.size,
      sourceURL: result.sourceURL,
      sourceSha256: result.sourceSha256,
      contentSha256: result.contentSha256,
    });
    publish({ stage: "local_complete", song: track });
    return { ok: true, result: { kind: "created", track } };
  } catch (error) {
    return { ok: false, error: localImportFailure(error, "inspecting_source") };
  } finally {
    finishLocalImport(event, controller);
  }
});

ipcMain.handle("local-import:cancel", (event) => {
  pendingExternalImports.delete(event.sender.id);
  const controller = activeLocalImports.get(event.sender.id);
  if (!controller) return false;
  controller.abort(new DOMException("Import cancelled", "AbortError"));
  activeLocalImports.delete(event.sender.id);
  return true;
});

ipcMain.handle("local-import:upload", async (event, { baseURL, adminToken, profileID, filePath } = {}) => {
  if (!localImportEnabled()) {
    return { ok: false, error: { stage: "syncing", code: "FEATURE_DISABLED", message: "Local link import is disabled in this build." } };
  }
  const controller = beginLocalImport(event);
  try {
    const paths = await ensureDirectories();
    const absolute = path.resolve(String(filePath || ""));
    if (!absolute.startsWith(path.resolve(paths.local) + path.sep)) {
      throw new LocalImportError("syncing", "INVALID_LOCAL_FILE", "Only a song already saved in the local Resonance library can be uploaded.");
    }
    const information = await fs.stat(absolute);
    if (!information.isFile() || information.size <= 0 || information.size > MAX_LOCAL_IMPORT_UPLOAD_BYTES) {
      throw new LocalImportError("syncing", "INVALID_LOCAL_FILE", "The local song cannot be uploaded because its size is invalid.");
    }
    if (!String(adminToken || "").trim()) {
      throw new LocalImportError("syncing", "ADMIN_KEY_REQUIRED", "Add a server admin key before uploading this local song.");
    }
    const base = normalizeBaseURL(baseURL);
    const filename = safeFilename(path.basename(absolute));
    const url = new URL("api/v1/admin/songs", base);
    url.searchParams.set("filename", filename);
    let completed = 0;
    const body = createReadStream(absolute);
    const publishUploadProgress = () => {
      if (!event.sender.isDestroyed()) {
        event.sender.send("local-import:progress", {
          stage: "syncing",
          profileID: String(profileID || "default"),
          currentFile: filename,
          completed,
          total: information.size,
        });
      }
    };
    body.on("data", (chunk) => {
      completed += chunk.length;
      publishUploadProgress();
    });
    controller.signal.addEventListener("abort", () => body.destroy(controller.signal.reason), { once: true });
    publishUploadProgress();
    const response = await fetch(url, {
      method: "PUT",
      headers: {
        ...profileHeaders(String(adminToken), profileID),
        "Content-Type": "application/octet-stream",
        "Content-Length": String(information.size),
      },
      body,
      duplex: "half",
      signal: controller.signal,
    });
    let responsePayload = null;
    try { responsePayload = await response.json(); } catch { /* Some server versions return no JSON body. */ }
    const remoteSong = response.status === 409
      ? responsePayload?.duplicate_of || responsePayload?.duplicateOf || null
      : responsePayload;
    if (!response.ok && !(response.status === 409 && remoteSong?.id)) throw await serverResponseError(response);
    completed = information.size;
    publishUploadProgress();
    event.sender.send("local-import:progress", {
      stage: "complete",
      profileID: String(profileID || "default"),
      currentFile: filename,
      completed,
      total: information.size,
    });
    return { ok: true, remoteSong };
  } catch (error) {
    return { ok: false, error: localImportFailure(error, "syncing") };
  } finally {
    finishLocalImport(event, controller);
  }
});

ipcMain.handle("library:delete", async (_event, filePath) => {
  const paths = await ensureDirectories();
  const absolute = path.resolve(String(filePath || ""));
  const allowed = [paths.local, paths.remote].some((directory) => absolute.startsWith(path.resolve(directory) + path.sep));
  if (!allowed) throw new Error("The selected file is outside the app library.");
  await fs.rm(absolute, { force: true });
  return true;
});

ipcMain.handle("library:storage", async () => {
  const paths = await ensureDirectories();
  const sumDirectory = async (directory) => {
    let total = 0;
    for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
      if (!entry.isFile()) continue;
      try { total += (await fs.stat(path.join(directory, entry.name))).size; } catch { /* file changed during scan */ }
    }
    return total;
  };
  const [localBytes, remoteBytes, disk] = await Promise.all([
    sumDirectory(paths.local),
    sumDirectory(paths.remote),
    fs.statfs(paths.local),
  ]);
  return {
    localBytes,
    remoteBytes,
    availableBytes: Number(disk.bavail) * Number(disk.bsize),
    capacityBytes: Number(disk.blocks) * Number(disk.bsize),
  };
});

function authorizationHeaders(token) {
  return { Authorization: `Bearer ${token}` };
}

function profileHeaders(token, profileID) {
  return {
    ...authorizationHeaders(token),
    "X-Resonance-Profile": String(profileID || "default"),
  };
}

ipcMain.handle("server:profiles:get", async (_event, { baseURL, token }) => {
  if (!token) throw new Error("Enter the server access token.");
  const base = normalizeBaseURL(baseURL);
  const response = await fetch(new URL("api/v1/profiles", base), { headers: authorizationHeaders(token) });
  if (!response.ok) throw await serverResponseError(response);
  return response.json();
});

ipcMain.handle("server:profiles:create", async (_event, { baseURL, token, name }) => {
  if (!token) throw new Error("Enter the server access token.");
  const base = normalizeBaseURL(baseURL);
  const response = await fetch(new URL("api/v1/profiles", base), {
    method: "POST",
    headers: { ...profileHeaders(token, "default"), "Content-Type": "application/json" },
    body: JSON.stringify({ name }),
  });
  if (!response.ok) throw await serverResponseError(response);
  return response.json();
});

ipcMain.handle("server:artwork", async (_event, { baseURL, token, profileID, songID }) => {
  if (!token) throw new Error("Enter the server access token.");
  if (!songID) throw new Error("Song artwork is unavailable.");
  const base = normalizeBaseURL(baseURL);
  const artworkURL = new URL(`api/v1/songs/${encodeURIComponent(songID)}/artwork`, base);
  const response = await fetch(artworkURL, { headers: profileHeaders(token, profileID) });
  if (!response.ok) throw await serverResponseError(response);
  const contentType = String(response.headers.get("content-type") || "").split(";", 1)[0].trim().toLocaleLowerCase();
  if (!SERVER_ARTWORK_TYPES.has(contentType)) throw new Error("Server returned an unsupported artwork format.");
  const declaredLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > MAX_SERVER_ARTWORK_BYTES) {
    throw new Error("Server artwork is too large.");
  }
  const bytes = await responseBytesWithLimit(response, MAX_SERVER_ARTWORK_BYTES);
  return `data:${contentType};base64,${bytes.toString("base64")}`;
});

ipcMain.handle("server:catalog", async (_event, { baseURL, token, profileID }) => {
  if (!token) throw new Error("Enter the server access token.");
  const base = normalizeBaseURL(baseURL);
  const response = await fetch(new URL("api/v1/songs", base), { headers: profileHeaders(token, profileID) });
  if (!response.ok) throw await serverResponseError(response);
  return response.json();
});

ipcMain.handle("server:playlists:get", async (_event, { baseURL, token, profileID }) => {
  if (!token) throw new Error("Enter the server access token.");
  const base = normalizeBaseURL(baseURL);
  const response = await fetch(new URL("api/v1/playlists", base), { headers: profileHeaders(token, profileID) });
  if (!response.ok) throw await serverResponseError(response);
  return response.json();
});

ipcMain.handle("server:playlists:put", async (_event, { baseURL, token, profileID, document }) => {
  if (!token) throw new Error("Enter the server access token.");
  const base = normalizeBaseURL(baseURL);
  const response = await fetch(new URL("api/v1/playlists", base), {
    method: "PUT",
    headers: {
      ...profileHeaders(token, profileID),
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify(document),
  });
  if (response.status !== 200 && response.status !== 409) throw await serverResponseError(response);
  return { status: response.status, document: await response.json() };
});

ipcMain.handle("server:listening-history:post", async (_event, { baseURL, token, profileID, entries }) => {
  if (!token) throw new Error("Enter the server access token.");
  if (!Array.isArray(entries) || entries.length === 0 || entries.length > 500) {
    throw new Error("Listening history must contain between 1 and 500 entries.");
  }
  const base = normalizeBaseURL(baseURL);
  const response = await fetch(new URL("api/v1/listening-history", base), {
    method: "POST",
    headers: {
      ...profileHeaders(token, profileID),
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({ client: "windows", entries }),
  });
  if (response.status === 404) return { supported: false, accepted: 0 };
  if (!response.ok) throw await serverResponseError(response);
  return { supported: true, ...(await response.json()) };
});

ipcMain.handle("server:sync", async (event, { baseURL, token, profileID, existing = [], songIDs = null }) => {
  if (!token) throw new Error("Enter the server access token.");
  const controller = beginServerTransfer(event);
  const { signal } = controller;
  let catalog = null;
  const downloaded = [];
  const replacedTrackIDs = [];
  const failed = [];
  try {
  const base = normalizeBaseURL(baseURL);
  {
    const response = await fetch(new URL("api/v1/songs", base), { headers: profileHeaders(token, profileID), signal });
    if (!response.ok) throw await serverResponseError(response);
    catalog = await response.json();
  }
  const paths = await ensureDirectories();
  const requested = Array.isArray(songIDs) ? new Set(songIDs) : null;
  const songs = (catalog.songs || []).filter((song) => !requested || requested.has(song.id));
  let completed = 0;
  for (const song of songs) {
    signal.throwIfAborted();
    const remoteName = song.filename || song.name || `Track-${song.id}.mp3`;
    const remoteModified = song.modified_at || song.modified_utc || null;
    const matching = existing.find((item) =>
      item.remoteID === song.id
      && matchesServerOrigin(item.sourceServer, base.origin)
      && (item.syncProfileID || "default") === (profileID || "default"));
    let current = false;
    if (matching?.filePath) {
      try {
        const information = await fs.stat(matching.filePath);
        const correctSize = !Number.isFinite(Number(song.size)) || information.size === Number(song.size);
        const correctRevision = !matching.remoteModified || !remoteModified || matching.remoteModified === remoteModified;
        current = information.isFile() && correctSize && correctRevision;
      } catch {
        current = false;
      }
    }
    if (current) {
      completed += 1;
      event.sender.send("server:transfer-progress", { direction: "download", currentFile: remoteName, completed, total: songs.length });
      continue;
    }
    event.sender.send("server:transfer-progress", { direction: "download", currentFile: remoteName, completed, total: songs.length });
    try {
      const fileURL = new URL(song.download_url, base);
      if (fileURL.origin !== base.origin) {
        throw new Error(`The server returned an unsafe cross-origin download URL for ${song.title || song.name || song.id}.`);
      }
      const destination = matching?.filePath && path.dirname(path.resolve(matching.filePath)) === path.resolve(paths.remote)
        ? matching.filePath
        : await uniqueDestination(paths.remote, remoteName);
      let downloadedSize = 0;
      let downloadedSHA256 = null;
      await retryServerDownload(async () => {
        const response = await fetch(fileURL, { headers: profileHeaders(token, profileID), signal });
        if (!response.ok) throw new Error(`Download failed for ${song.title || song.name || song.id} (HTTP ${response.status})`);
        const temporary = `${destination}.${randomUUID()}.part`;
        try {
          const downloadedFile = await writeResponseToFile(response, temporary, { signal, expectedSize: Number(song.size) });
          downloadedSize = downloadedFile.size;
          downloadedSHA256 = downloadedFile.sha256;
          signal.throwIfAborted();
          await fs.rename(temporary, destination);
        } catch (error) {
          await fs.rm(temporary, { force: true });
          throw error;
        }
      }, {
        signal,
        onRetry: ({ nextAttempt }) => event.sender.send("server:transfer-progress", {
          direction: "download",
          currentFile: `Retrying ${remoteName} (${nextAttempt}/${SERVER_DOWNLOAD_ATTEMPTS})`,
          completed,
          total: songs.length,
        }),
      });
      if (matching?.id) replacedTrackIDs.push(matching.id);
      downloaded.push(await enrichedTrack(destination, {
        id: matching?.id,
        title: song.title || path.basename(remoteName, path.extname(remoteName)),
        artist: song.artist || "Unknown Artist",
        album: song.album || "Server Library",
        remoteID: song.id,
        sourceServer: base.origin,
        syncProfileID: profileID || "default",
        remoteModified,
        size: downloadedSize,
        contentSha256: downloadedSHA256,
      }));
    } catch (error) {
      if (error?.name === "AbortError") throw error;
      failed.push({
        id: song.id,
        title: song.title || song.name || path.basename(remoteName, path.extname(remoteName)),
        artist: song.artist || "",
        filename: remoteName,
        attempts: SERVER_DOWNLOAD_ATTEMPTS,
        message: error?.message || "Download failed.",
      });
    }
    completed += 1;
    event.sender.send("server:transfer-progress", { direction: "download", currentFile: song.filename || song.name, completed, total: songs.length });
  }
  return { catalog, downloaded, replacedTrackIDs, failed };
  } catch (error) {
    if (error?.name === "AbortError") return { catalog, downloaded, replacedTrackIDs, failed, cancelled: true };
    throw error;
  } finally {
    finishServerTransfer(event, controller);
  }
});

ipcMain.handle("server:upload", async (event, { baseURL, adminToken, profileID }) => {
  if (!adminToken) throw new Error("Enter the server admin key.");
  const selection = await dialog.showOpenDialog(mainWindow, {
    title: "Upload music to Resonance Server",
    properties: ["openFile", "multiSelections"],
    filters: [{ name: "Audio", extensions: [...AUDIO_EXTENSIONS].map((item) => item.slice(1)) }],
  });
  if (selection.canceled) return { uploaded: 0 };
  const controller = beginServerTransfer(event);
  const { signal } = controller;
  let uploaded = 0;
  try {
  const base = normalizeBaseURL(baseURL);
  for (const filePath of selection.filePaths) {
    signal.throwIfAborted();
    const filename = path.basename(filePath);
    event.sender.send("server:transfer-progress", { direction: "upload", currentFile: filename, completed: uploaded, total: selection.filePaths.length });
    const information = await fs.stat(filePath);
    const url = new URL("api/v1/admin/songs", base);
    url.searchParams.set("filename", filename);
    const body = createReadStream(filePath);
    const abortBody = () => body.destroy(new Error("Upload cancelled"));
    signal.addEventListener("abort", abortBody, { once: true });
    let response;
    try {
      response = await fetch(url, {
        method: "PUT",
        headers: {
          ...profileHeaders(adminToken, profileID),
          "Content-Type": "application/octet-stream",
          "Content-Length": String(information.size),
        },
        body,
        duplex: "half",
        signal,
      });
    } finally {
      signal.removeEventListener("abort", abortBody);
      body.destroy();
    }
    if (!response.ok) throw new Error(`Upload failed for ${filename} (HTTP ${response.status})`);
    uploaded += 1;
    event.sender.send("server:transfer-progress", { direction: "upload", currentFile: filename, completed: uploaded, total: selection.filePaths.length });
  }
  return { uploaded };
  } catch (error) {
    if (error?.name === "AbortError") return { uploaded, cancelled: true };
    throw error;
  } finally {
    finishServerTransfer(event, controller);
  }
});

ipcMain.handle("server:cancel-transfer", (event) => {
  const controller = activeServerTransfers.get(event.sender.id);
  if (!controller) return false;
  controller.abort();
  return true;
});

ipcMain.handle("server:delete", async (_event, { baseURL, adminToken, profileID, songID }) => {
  const base = normalizeBaseURL(baseURL);
  const response = await fetch(new URL(`api/v1/admin/songs/${songID}`, base), { method: "DELETE", headers: profileHeaders(adminToken, profileID) });
  if (!response.ok) throw new Error(`Server returned HTTP ${response.status}`);
  return true;
});

ipcMain.handle("server:open-admin", async (_event, baseURL) => {
  const base = normalizeBaseURL(baseURL);
  await shell.openExternal(new URL("admin", base).href);
});

module.exports = { safeFilename, normalizeBaseURL, publicTrack };
