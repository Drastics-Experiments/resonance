const { app, BrowserWindow, dialog, ipcMain, safeStorage, shell } = require("electron");
const { autoUpdater } = require("electron-updater");
const { randomUUID } = require("node:crypto");
const fs = require("node:fs/promises");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const { readAudioMetadata } = require("./metadata.cjs");

const AUDIO_EXTENSIONS = new Set([".aac", ".aif", ".aiff", ".alac", ".flac", ".m4a", ".m4b", ".mp3", ".ogg", ".opus", ".wav"]);

let mainWindow;

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
autoUpdater.on("error", (error) => publishUpdateStatus("error", { message: error.message || "Update check failed" }));

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

async function ensureDirectories() {
  const paths = applicationPaths();
  await Promise.all([fs.mkdir(paths.local, { recursive: true }), fs.mkdir(paths.remote, { recursive: true })]);
  return paths;
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
    album: details.album || "Imported",
    duration: Number(details.duration) || 0,
    artwork: details.artwork || null,
    size: Number(details.size) || 0,
    filePath,
    fileUrl: pathToFileURL(filePath).href,
    remoteID: details.remoteID || null,
    sourceServer: details.sourceServer || null,
    remoteModified: details.remoteModified || null,
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

async function authenticatedJSON(url, token) {
  const response = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (!response.ok) throw await serverResponseError(response);
  return response.json();
}

async function serverResponseError(response) {
  let message = "";
  let body = "";
  try { body = await response.text(); } catch { /* no response body */ }
  try {
    const payload = JSON.parse(body);
    message = typeof payload?.error === "string" ? payload.error : "";
  } catch {
    message = body.trim();
  }
  return new Error(`Server returned HTTP ${response.status}${message ? `: ${message}` : ""}`);
}

function createWindow() {
  mainWindow = new BrowserWindow({
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
  mainWindow.loadFile(path.join(__dirname, "ui", "index.html"));
}

app.whenReady().then(async () => {
  await ensureDirectories();
  createWindow();
  if (app.isPackaged) setTimeout(() => autoUpdater.checkForUpdates().catch(() => {}), 10000);
  app.on("activate", () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});

app.on("window-all-closed", () => { if (process.platform !== "darwin") app.quit(); });

ipcMain.handle("update:check", async () => {
  if (!app.isPackaged) return { supported: false };
  await autoUpdater.checkForUpdates();
  return { supported: true };
});

ipcMain.handle("update:install", () => {
  if (!app.isPackaged) return false;
  autoUpdater.quitAndInstall(false, true);
  return true;
});

ipcMain.handle("library:load", async () => {
  const { state } = await ensureDirectories();
  try {
    const stored = JSON.parse(await fs.readFile(state, "utf8"));
    const tracks = await Promise.all((stored.tracks || []).filter((track) => track.filePath).map(async (track) => {
      try {
        const information = await fs.stat(track.filePath);
        if (!information.isFile()) return null;
        return enrichedTrack(track.filePath, { ...track, size: information.size });
      } catch {
        return null;
      }
    }));
    stored.tracks = tracks.filter(Boolean);
    await fs.writeFile(state, JSON.stringify({
      ...stored,
      tracks: stored.tracks.map(({ fileUrl, ...track }) => track),
    }, null, 2), "utf8");
    return stored;
  } catch {
    return null;
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
    playlistRevision: Number.isInteger(state.playlistRevision) && state.playlistRevision >= 0 ? state.playlistRevision : 0,
    knownRemotePlaylistIDs: Array.isArray(state.knownRemotePlaylistIDs) ? state.knownRemotePlaylistIDs : [],
    dirtyPlaylistIDs: Array.isArray(state.dirtyPlaylistIDs) ? state.dirtyPlaylistIDs : [],
    deletedPlaylistIDs: Array.isArray(state.deletedPlaylistIDs) ? state.deletedPlaylistIDs : [],
    playlistSyncServerURL: typeof state.playlistSyncServerURL === "string" ? state.playlistSyncServerURL : null,
  };
  await fs.writeFile(paths.state, JSON.stringify(safeState, null, 2), "utf8");
  return true;
});

ipcMain.handle("server:credentials:load", async () => {
  const { credentials } = await ensureDirectories();
  if (!safeStorage.isEncryptionAvailable()) return { clientToken: "", adminToken: "" };
  try {
    const encrypted = await fs.readFile(credentials);
    return JSON.parse(safeStorage.decryptString(encrypted));
  } catch {
    return { clientToken: "", adminToken: "" };
  }
});

ipcMain.handle("server:credentials:save", async (_event, value) => {
  if (!safeStorage.isEncryptionAvailable()) throw new Error("Windows credential encryption is unavailable.");
  const { credentials } = await ensureDirectories();
  const payload = JSON.stringify({ clientToken: String(value.clientToken || ""), adminToken: String(value.adminToken || "") });
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

ipcMain.handle("library:delete", async (_event, filePath) => {
  const paths = await ensureDirectories();
  const absolute = path.resolve(String(filePath || ""));
  const allowed = [paths.local, paths.remote].some((directory) => absolute.startsWith(path.resolve(directory) + path.sep));
  if (!allowed) throw new Error("The selected file is outside the app library.");
  await fs.rm(absolute, { force: true });
  return true;
});

ipcMain.handle("server:catalog", async (_event, { baseURL, token }) => {
  if (!token) throw new Error("Enter the server access token.");
  const base = normalizeBaseURL(baseURL);
  return authenticatedJSON(new URL("api/v1/songs", base), token);
});

ipcMain.handle("server:playlists:get", async (_event, { baseURL, token }) => {
  if (!token) throw new Error("Enter the server access token.");
  const base = normalizeBaseURL(baseURL);
  return authenticatedJSON(new URL("api/v1/playlists", base), token);
});

ipcMain.handle("server:playlists:put", async (_event, { baseURL, token, document }) => {
  if (!token) throw new Error("Enter the server access token.");
  const base = normalizeBaseURL(baseURL);
  const response = await fetch(new URL("api/v1/playlists", base), {
    method: "PUT",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify(document),
  });
  if (response.status !== 200 && response.status !== 409) throw await serverResponseError(response);
  return { status: response.status, document: await response.json() };
});

ipcMain.handle("server:sync", async (event, { baseURL, token, existing = [], songIDs = null }) => {
  if (!token) throw new Error("Enter the server access token.");
  const base = normalizeBaseURL(baseURL);
  const catalog = await authenticatedJSON(new URL("api/v1/songs", base), token);
  const paths = await ensureDirectories();
  const requested = Array.isArray(songIDs) ? new Set(songIDs) : null;
  const downloaded = [];
  const replacedTrackIDs = [];
  const songs = (catalog.songs || []).filter((song) => !requested || requested.has(song.id));
  let completed = 0;
  for (const song of songs) {
    const remoteName = song.filename || song.name || `Track-${song.id}.mp3`;
    const remoteModified = song.modified_at || song.modified_utc || null;
    const matching = existing.find((item) => item.remoteID === song.id && (!item.sourceServer || item.sourceServer === base.origin));
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
    const fileURL = new URL(song.download_url, base);
    const response = await fetch(fileURL, { headers: { Authorization: `Bearer ${token}` } });
    if (!response.ok) throw new Error(`Download failed for ${song.title || song.name || song.id} (HTTP ${response.status})`);
    const destination = matching?.filePath && path.dirname(path.resolve(matching.filePath)) === path.resolve(paths.remote)
      ? matching.filePath
      : await uniqueDestination(paths.remote, remoteName);
    const temporary = `${destination}.${randomUUID()}.part`;
    const bytes = Buffer.from(await response.arrayBuffer());
    if (Number.isFinite(Number(song.size)) && bytes.length !== Number(song.size)) {
      throw new Error(`Incomplete download for ${song.title || song.name || song.id}`);
    }
    try {
      await fs.writeFile(temporary, bytes);
      await fs.rename(temporary, destination);
    } catch (error) {
      await fs.rm(temporary, { force: true });
      throw error;
    }
    if (matching?.id) replacedTrackIDs.push(matching.id);
    downloaded.push(await enrichedTrack(destination, {
      id: matching?.id,
      title: song.title || path.basename(remoteName, path.extname(remoteName)),
      artist: song.artist || "Unknown Artist",
      album: song.album || "Server Library",
      remoteID: song.id,
      sourceServer: base.origin,
      remoteModified,
      size: bytes.length,
    }));
    completed += 1;
    event.sender.send("server:transfer-progress", { direction: "download", currentFile: song.filename || song.name, completed, total: songs.length });
  }
  return { catalog, downloaded, replacedTrackIDs };
});

ipcMain.handle("server:upload", async (event, { baseURL, adminToken }) => {
  if (!adminToken) throw new Error("Enter the server admin key.");
  const selection = await dialog.showOpenDialog(mainWindow, {
    title: "Upload music to Resonance Server",
    properties: ["openFile", "multiSelections"],
    filters: [{ name: "Audio", extensions: [...AUDIO_EXTENSIONS].map((item) => item.slice(1)) }],
  });
  if (selection.canceled) return { uploaded: 0 };
  const base = normalizeBaseURL(baseURL);
  let uploaded = 0;
  for (const filePath of selection.filePaths) {
    const filename = path.basename(filePath);
    event.sender.send("server:transfer-progress", { direction: "upload", currentFile: filename, completed: uploaded, total: selection.filePaths.length });
    const body = await fs.readFile(filePath);
    const url = new URL("api/v1/admin/songs", base);
    url.searchParams.set("filename", filename);
    const response = await fetch(url, { method: "PUT", headers: { Authorization: `Bearer ${adminToken}`, "Content-Type": "application/octet-stream" }, body });
    if (!response.ok) throw new Error(`Upload failed for ${filename} (HTTP ${response.status})`);
    uploaded += 1;
    event.sender.send("server:transfer-progress", { direction: "upload", currentFile: filename, completed: uploaded, total: selection.filePaths.length });
  }
  return { uploaded };
});

ipcMain.handle("server:delete", async (_event, { baseURL, adminToken, songID }) => {
  const base = normalizeBaseURL(baseURL);
  const response = await fetch(new URL(`api/v1/admin/songs/${songID}`, base), { method: "DELETE", headers: { Authorization: `Bearer ${adminToken}` } });
  if (!response.ok) throw new Error(`Server returned HTTP ${response.status}`);
  return true;
});

ipcMain.handle("server:open-admin", async (_event, baseURL) => {
  const base = normalizeBaseURL(baseURL);
  await shell.openExternal(new URL("admin", base).href);
});

module.exports = { safeFilename, normalizeBaseURL, publicTrack };
