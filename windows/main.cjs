const { app, BrowserWindow, clipboard, dialog, ipcMain, Menu, nativeImage, protocol, shell, Tray, webContents } = require("electron");
const { autoUpdater } = require("electron-updater");
const { spawn } = require("node:child_process");
const { createHash, createHmac, randomBytes, randomUUID } = require("node:crypto");
const { createReadStream } = require("node:fs");
const fs = require("node:fs/promises");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const { crashSafeReplace, crashSafeReplaceMirrored, readPrimaryOrBackup } = require("./crash-safe-file.cjs");
const { DiscordRPCClient, validDiscordApplicationID } = require("./discord-rpc.cjs");
const {
  cachedConfigMeetsRevisionFloor,
  clientConfigRevisionFloor,
  commitClientConfigRecord,
  currentFloorSafeCachedConfig,
} = require("./client-config-state.cjs");
const {
  CLIENT_CONFIG_MAX_BYTES,
  clientConfigRequestContext,
  configCacheKey,
  createClientConfigCacheRecord,
  monotonicClientConfigRevision,
  safeClientConfig,
  validCachedClientConfig,
  verifyClientConfigResponse,
} = require("./client-config.cjs");
const { MAX_SERVER_MEDIA_BYTES, adoptDownloadedFile, writeResponseToFile } = require("./download-file.cjs");
const { sanitizeWindowsFilename, windowsCollisionFilename } = require("./filename-policy.cjs");
const { isManagedLibraryFile } = require("./library-paths.cjs");
const { normalizeListeningHistoryUploadEntries } = require("./listening-history.cjs");
const {
  UNLINKED_DOWNLOAD_MIGRATION_ID,
  migrateUnlinkedDownloads,
} = require("./library-update-migration.cjs");
const { readAudioMetadata } = require("./metadata.cjs");
const {
  normalizeSourceIdentities,
  normalizeSourceIdentity,
  preservedMediaSourceURL,
  sanitizePersistedJSON,
  sanitizePersistedSourceIdentities,
  sanitizePersistedSourceIdentity,
} = require("./provenance.cjs");
const { readResponseJSON, readResponseText } = require("./response-body.cjs");
const { createRenewablePolicyLease } = require("./policy-lease.cjs");
const {
  SERVER_DOWNLOAD_ATTEMPTS,
  createServerCatalogSnapshotStore,
  createServerDownloadProgressPublisher,
  retryServerDownload,
  serverDownloadImportedMetadata,
  serverDownloadMetadata,
  serverDownloadMetadataContextMatches,
  serverDownloadMetadataIsResolved,
  serverDownloadMetadataSnapshot,
  serverDownloadProgressEvent,
} = require("./server-download.cjs");
const { fetchSameOrigin } = require("./server-request.cjs");
const {
  SERVER_STREAM_SCHEME,
  ServerStreamValidationError,
  createExactLengthRelay,
  parseSingleByteRange,
  remoteStreamHistoryTrackID,
  serverStreamSongIsVideo,
  serverStreamURL,
  streamSessionIDFromURL,
  supportedMediaSize,
  validateStreamResponse,
} = require("./server-stream.cjs");
const {
  ListenAlongValidationError,
  canonicalListenAlongCode,
  canonicalListenAlongMediaKind,
  canonicalListenAlongRevision,
  canonicalListenAlongSnapshot,
  normalizeListenAlongResponse,
  publicListenAlongEvent,
} = require("./listen-along.cjs");
const { catalogSHA256, normalizeServerBaseURL } = require("./server-policy.cjs");
const { conciseUpdaterError, installDownloadedWindowsUpdate, resolveWindowsUpdateFeed } = require("./updater-feed.cjs");
const {
  verifyDownloadedWindowsUpdate,
} = require("./updater-auth.cjs");
const { LocalImportError, isSpotifyURL, searchYouTubeAudioSources, youtubeVideoID } = require("./local-import-core.cjs");
const { importFileBackedSource, searchFileBackedSources } = require("./local-debrid.cjs");
const {
  artworkFileDataURL,
  fetchArtwork,
  importConfirmedSource,
  resolveLocalImportDownloadSource,
  resolveLocalImportMetadata,
  resolveLocalImportSource,
  safeArtworkURL,
} = require("./local-import-platform.cjs");
const { looksLikeLink, searchAllPlatforms } = require("./local-search.cjs");
const { downloadResolvedSoundCloudAudio, isSoundCloudURL, resolveSoundCloudAudio } = require("./local-soundcloud.cjs");
const { downloadResolvedAudio, resolveYouTubeAudio } = require("./local-youtube.cjs");
const { policyBlockedUploadEntries, serverUploadFilename } = require("./server-upload.cjs");
const { readServerUploadResponse } = require("./server-upload-response.cjs");
const {
  ACCOUNT_SIGN_IN_URL,
  authorizationURL,
  createPKCE,
  exchangeAuthCode,
  fetchAuthConfiguration,
  publicSession,
  refreshAuthSession,
  revokeAuthSession,
} = require("./social-auth.cjs");
const {
  allowedAccountAvatarURL,
  fetchAccountAvatar,
  isSafeAccountAvatarDataURL,
} = require("./account-avatar.cjs");
const windowsPackage = require("./package.json");

function developmentInstanceMetadata() {
  if (app.isPackaged) return null;
  const worktreeID = String(process.env.RESONANCE_WORKTREE_ID || "").trim();
  if (!/^[a-z0-9-]{1,80}$/.test(worktreeID)) return null;
  const requestedName = String(process.env.RESONANCE_INSTANCE_NAME || "").trim();
  const displayName = /^[A-Za-z0-9 ._\-\[\]]{1,100}$/.test(requestedName)
    ? requestedName
    : `Resonance Windows [${worktreeID}]`;
  return { displayName, worktreeID };
}

const developmentInstance = developmentInstanceMetadata();
const resonanceApplicationName = developmentInstance?.displayName || "Resonance";
if (developmentInstance) {
  app.setName(resonanceApplicationName);
  app.setPath("userData", path.join(
    app.getPath("appData"),
    "Resonance Worktrees",
    developmentInstance.worktreeID,
    "windows",
  ));
}

protocol.registerSchemesAsPrivileged([{
  scheme: SERVER_STREAM_SCHEME,
  privileges: {
    standard: true,
    secure: true,
    stream: true,
  },
}]);

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
const VIDEO_EXTENSIONS = new Set([".mp4", ".mov", ".m4v", ".webm"]);
const SERVER_ARTWORK_TYPES = new Set(["image/avif", "image/gif", "image/jpeg", "image/png", "image/webp"]);
const MAX_SERVER_ARTWORK_BYTES = 8 * 1024 * 1024;
const MAX_PROFILE_PICTURE_SOURCE_BYTES = 32 * 1024 * 1024;
const MAX_LOCAL_IMPORT_UPLOAD_BYTES = 256 * 1024 * 1024;
const MAX_LOCAL_IMPORT_PREVIEW_BYTES = 32 * 1024 * 1024;
const AUTOMATIC_UPDATE_CHECK_DELAY_MS = 10_000;
const AUTOMATIC_UPDATE_CHECK_INTERVAL_MS = 5 * 60 * 1000;
const MAX_SERVER_UPLOAD_BATCH_FILES = 500;
const MAX_SERVER_UPLOAD_MANIFESTS = 20;
const MAX_SERVER_UPLOAD_RETRY_RECORDS = MAX_SERVER_UPLOAD_BATCH_FILES * MAX_SERVER_UPLOAD_MANIFESTS;
const SERVER_UPLOAD_RETRY_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000;
const REMOTE_SONG_METADATA_CACHE_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000;
const MAX_REMOTE_SONG_METADATA_CACHE_RECORDS = 2_000;
const MAX_SERVER_STREAM_SESSIONS = 32;
const MAX_SERVER_STREAM_SESSIONS_PER_OWNER = 2;
const MAX_SERVER_STREAM_REQUESTS_PER_SESSION = 4;
const MAX_ACTIVE_SERVER_STREAM_REQUESTS = 32;
const MAX_SERVER_STREAM_CATALOG_BYTES = 8 * 1024 * 1024;
const MAX_SERVER_JSON_RESPONSE_BYTES = 8 * 1024 * 1024;
const MAX_SERVER_ERROR_RESPONSE_BYTES = 64 * 1024;
const MAX_SOURCE_IMPORT_RESPONSE_BYTES = 512 * 1024;
const SERVER_STREAM_SESSION_TTL_MS = 8 * 60 * 60 * 1000;
const SERVER_STREAM_REQUEST_TIMEOUT_MS = 2 * 60 * 60 * 1000;
const SERVER_STREAM_IDLE_TIMEOUT_MS = 45 * 1000;
const MAX_LISTEN_ALONG_MEDIA_SESSIONS_PER_SESSION = 2;
const MAX_LISTEN_ALONG_JSON_BYTES = 512 * 1024;
// Listen Along has no socket endpoint in the current Core contract, so the
// desktop clients use bounded polling. Keep the healthy-room cadence short
// enough that a host action feels immediate; failures still use the existing
// exponential backoff below.
const LISTEN_ALONG_POLL_INTERVAL_MS = 250;
const LISTEN_ALONG_POLL_MAX_BACKOFF_MS = 30_000;
const LISTEN_ALONG_REQUEST_TIMEOUT_MS = 15_000;
const LISTEN_ALONG_SESSION_TTL_MS = 8 * 60 * 60 * 1000;
const WINDOWS_APP_BUILD = Number(windowsPackage.resonanceBuild);
if (!Number.isSafeInteger(WINDOWS_APP_BUILD) || WINDOWS_APP_BUILD < 1) {
  throw new Error("windows/package.json must contain a positive resonanceBuild for client-config audience targeting.");
}

let mainWindow;
let applicationQuitRequested = false;
let backgroundTray = null;
const DEFAULT_APP_THEME = "midnight";
const APP_THEME_IDS = new Set([DEFAULT_APP_THEME, "ocean", "forest", "sunset"]);
let runtimeAppPreferences = { theme: DEFAULT_APP_THEME, runInBackground: false, discordRichPresence: false };
let currentDiscordPresenceStatus = { state: "disabled", message: "Rich Presence is off.", applicationConfigured: false };
const activeServerTransfers = new Map();
let serverTransferGeneration = 0;
const activeLocalImports = new Map();
const activeLocalImportPreviews = new Map();
const cachedLocalImportPreviews = new Map();
const pendingExternalImports = new Map();
let librarySaveQueue = Promise.resolve();
let credentialSaveQueue = Promise.resolve();
let accountSessionSaveQueue = Promise.resolve();
let accountSession = null;
let accountSessionGeneration = 0;
let pendingAccountSignIn = null;
let accountSessionRefreshTimer = null;
let accountSessionRefreshInFlight = null;
let serverUploadRetrySaveQueue = Promise.resolve();
let serverUploadRetryLoadPromise = null;
let clientConfigStateLoadPromise = null;
let clientConfigStateSaveQueue = Promise.resolve();
let clientConfigMutationQueue = Promise.resolve();
let clientConfigState = null;
const serverUploadRetries = new Map();
const serverStreamSessions = new Map();
const listenAlongSessions = new Map();
const listenAlongMediaSessions = new Map();
const listenAlongMediaPending = new Map();
const serverCatalogSnapshots = createServerCatalogSnapshotStore();
const rendererCredentialFingerprints = new Map();
const rendererCredentialEpochs = new Map();
const credentialFingerprintKey = randomBytes(32);
let currentWindowsUpdateStatus = { type: "idle" };
let windowsUpdateCheckPromise = null;
let verifiedWindowsUpdate = null;
let windowsUpdateVerificationPromise = null;
let automaticUpdateCheckTimer = null;
let automaticUpdateCheckInterval = null;

const bundledDiscordApplicationID = validDiscordApplicationID(
  process.env.RESONANCE_DISCORD_CLIENT_ID || windowsPackage.resonanceDiscordApplicationID,
);
const discordRPC = new DiscordRPCClient({
  onStatus(status) {
    currentDiscordPresenceStatus = status;
    if (mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.webContents.send("app:discord-presence:status", status);
    }
  },
});
currentDiscordPresenceStatus = discordRPC.configure({
  enabled: false,
  applicationID: bundledDiscordApplicationID,
});

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

function bundledFFmpegPath() {
  let executable;
  try { executable = require("ffmpeg-static"); }
  catch { throw new Error("Video thumbnails are unavailable in this build."); }
  if (typeof executable !== "string" || !executable) {
    throw new Error("Video thumbnails are unavailable in this build.");
  }
  return executable.replace(/app\.asar([\\/])/i, "app.asar.unpacked$1");
}

function captureVideoFrame(filePath, seconds) {
  return new Promise((resolve, reject) => {
    const child = spawn(bundledFFmpegPath(), [
      "-hide_banner", "-loglevel", "error",
      "-ss", Math.max(0, seconds).toFixed(3),
      "-i", filePath,
      "-frames:v", "1",
      "-vf", "scale=240:135:force_original_aspect_ratio=increase,crop=240:135",
      "-f", "image2pipe", "-vcodec", "mjpeg", "pipe:1",
    ], { windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
    const chunks = [];
    let byteCount = 0;
    let stderr = "";
    let settled = false;
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      callback(value);
    };
    child.stdout.on("data", (chunk) => {
      byteCount += chunk.length;
      if (byteCount > 2 * 1024 * 1024) {
        child.kill("SIGKILL");
        finish(reject, new Error("A video thumbnail was unexpectedly large."));
        return;
      }
      chunks.push(chunk);
    });
    child.stderr.on("data", (chunk) => { stderr = `${stderr}${chunk}`.slice(-2_000); });
    child.on("error", (error) => finish(reject, error));
    child.on("close", (code) => {
      if (settled) return;
      const data = Buffer.concat(chunks);
      if (code === 0 && data.length) finish(resolve, `data:image/jpeg;base64,${data.toString("base64")}`);
      else finish(reject, new Error(stderr.trim() || "Video thumbnail extraction failed."));
    });
  });
}

function usesPreviewCredentialStore() {
  return process.platform === "darwin" && !app.isPackaged;
}

function canonicalCredentialToken(value) {
  const token = String(value || "").trim();
  if (token.length > 8192 || /[\u0000-\u001f\u007f]/.test(token)) {
    throw new Error("Server credentials must be at most 8192 characters and contain no control characters.");
  }
  return token;
}

function canonicalServerCredentials(value) {
  return {
    clientToken: canonicalCredentialToken(value?.clientToken),
    adminToken: canonicalCredentialToken(value?.adminToken),
  };
}

function previewCredentialStorePath() {
  return path.join(app.getPath("userData"), "server-credentials.json");
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

async function persistServerCredentials(credentialsValue) {
  if (usesPreviewCredentialStore()) {
    await writePreviewCredentials(credentialsValue);
    return;
  }
  const safeStorage = encryptedCredentialStorage();
  if (!safeStorage.isEncryptionAvailable()) throw new Error("Windows credential encryption is unavailable.");
  const { credentials, credentialsBackup } = await ensureDirectories();
  const payload = JSON.stringify(credentialsValue);
  const save = credentialSaveQueue
    .catch(() => {})
    .then(() => crashSafeReplace(credentials, safeStorage.encryptString(payload), { backupPath: credentialsBackup }));
  credentialSaveQueue = save;
  await save;
}

function previewAccountSessionPath() {
  return path.join(app.getPath("userData"), "account-session.json");
}

function decodeAccountAvatar(bytes) {
  let image;
  try {
    image = nativeImage.createFromBuffer(bytes);
  } catch {
    return null;
  }
  if (!image || image.isEmpty?.()) return null;
  const size = image.getSize?.();
  if (!size || !Number.isSafeInteger(size.width) || !Number.isSafeInteger(size.height)) return null;
  let png;
  try {
    png = image.toPNG();
  } catch {
    return null;
  }
  if (!Buffer.isBuffer(png) || !png.length) return null;
  return {
    width: size.width,
    height: size.height,
    dataURL: `data:image/png;base64,${png.toString("base64")}`,
  };
}

async function hydrateAccountSessionAvatar(session) {
  if (!session?.imageURL || isSafeAccountAvatarDataURL(session.imageURL)) return session;
  const imageURL = await fetchAccountAvatar(session.imageURL, { decodeImage: decodeAccountAvatar });
  return Object.freeze({ ...session, imageURL });
}

function canonicalStoredAccountSession(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const accessToken = canonicalCredentialToken(value.accessToken);
  const refreshToken = canonicalCredentialToken(value.refreshToken);
  const email = String(value.email || "").trim().toLowerCase();
  const role = value.role === "admin" ? "admin" : value.role === "member" ? "member" : null;
  const expiresAt = Number(value.expiresAt);
  const baseURL = normalizeServerBaseURL(value.baseURL, { allowInsecureLoopback: !app.isPackaged }).origin;
  if (!accessToken || !refreshToken || !email || !role || !Number.isFinite(expiresAt)) return null;
  const accountID = String(value.accountID || "").trim() || null;
  const profileID = String(value.profileID || "").trim() || null;
  const displayName = String(value.displayName || "").trim() || null;
  let imageURL = null;
  if (value.imageURL) {
    imageURL = isSafeAccountAvatarDataURL(value.imageURL);
    if (!imageURL) {
      const candidate = allowedAccountAvatarURL(value.imageURL);
      if (!candidate) return null;
      imageURL = candidate.href;
    }
  }
  return { accessToken, refreshToken, email, role, expiresAt, baseURL, accountID, profileID, displayName, imageURL };
}

async function readAccountSession() {
  let rawValue = null;
  if (usesPreviewCredentialStore()) {
    try { rawValue = JSON.parse(await fs.readFile(previewAccountSessionPath(), "utf8")); }
    catch { return null; }
  } else {
    const { accountSession: destination, accountSessionBackup } = await ensureDirectories();
    const safeStorage = encryptedCredentialStorage();
    if (!safeStorage.isEncryptionAvailable()) return null;
    try {
      rawValue = (await readPrimaryOrBackup(destination, (encrypted) =>
        JSON.parse(safeStorage.decryptString(encrypted)), { backupPath: accountSessionBackup })).value;
    } catch {
      return null;
    }
  }
  try { return canonicalStoredAccountSession(rawValue); }
  catch { return null; }
}

async function persistAccountSession(value) {
  const session = canonicalStoredAccountSession(value);
  if (!session || (session.imageURL && !isSafeAccountAvatarDataURL(session.imageURL))) {
    throw new Error("The account session is invalid or its avatar was not validated.");
  }
  const save = accountSessionSaveQueue
    .catch(() => {})
    .then(async () => {
      if (usesPreviewCredentialStore()) {
        const destination = previewAccountSessionPath();
        await fs.mkdir(path.dirname(destination), { recursive: true, mode: 0o700 });
        await atomicWriteFile(destination, JSON.stringify(session), { encoding: "utf8", mode: 0o600 });
        await fs.chmod(destination, 0o600);
        return;
      }
      const safeStorage = encryptedCredentialStorage();
      if (!safeStorage.isEncryptionAvailable()) throw new Error("Windows account encryption is unavailable.");
      const { accountSession: destination, accountSessionBackup } = await ensureDirectories();
      await crashSafeReplace(
        destination,
        safeStorage.encryptString(JSON.stringify(session)),
        { backupPath: accountSessionBackup },
      );
    });
  accountSessionSaveQueue = save;
  await save;
}

async function clearPersistedAccountSession() {
  accountSessionGeneration += 1;
  accountSession = null;
  if (accountSessionRefreshTimer) clearTimeout(accountSessionRefreshTimer);
  accountSessionRefreshTimer = null;
  const paths = applicationPaths();
  const clear = accountSessionSaveQueue
    .catch(() => {})
    .then(() => Promise.all([
      fs.rm(previewAccountSessionPath(), { force: true }).catch(() => undefined),
      fs.rm(paths.accountSession, { force: true }).catch(() => undefined),
      fs.rm(paths.accountSessionBackup, { force: true }).catch(() => undefined),
    ]));
  accountSessionSaveQueue = clear;
  await clear;
}

async function purgeLegacyServerCredentials() {
  const paths = applicationPaths();
  await Promise.all([
    fs.rm(previewCredentialStorePath(), { force: true }).catch(() => undefined),
    fs.rm(paths.credentials, { force: true }).catch(() => undefined),
    fs.rm(paths.credentialsBackup, { force: true }).catch(() => undefined),
  ]);
}

function publishAccountSession(error = null) {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send("account:session-changed", {
      session: publicSession(accountSession),
      error: error ? String(error.message || error) : null,
    });
  }
}

function scheduleAccountSessionRefresh() {
  if (accountSessionRefreshTimer) clearTimeout(accountSessionRefreshTimer);
  accountSessionRefreshTimer = null;
  if (!accountSession) return;
  const delay = Math.max(5_000, Math.min(2_147_000_000, accountSession.expiresAt - Date.now() - 5 * 60_000));
  accountSessionRefreshTimer = setTimeout(() => {
    accountSessionRefreshTimer = null;
    void refreshCurrentAccountSession().catch((error) => {
      publishAccountSession(error);
      if (accountSession && accountSession.expiresAt > Date.now()) {
        accountSessionRefreshTimer = setTimeout(() => {
          accountSessionRefreshTimer = null;
          void refreshCurrentAccountSession().catch(publishAccountSession);
        }, 60_000);
        accountSessionRefreshTimer.unref?.();
      }
    });
  }, delay);
  accountSessionRefreshTimer.unref?.();
}

async function refreshCurrentAccountSession(migrationProfileID = null) {
  if (!accountSession) return null;
  if (accountSessionRefreshInFlight) return accountSessionRefreshInFlight;
  const active = accountSession;
  const generation = accountSessionGeneration;
  const refresh = (async () => {
    const configuration = await fetchAuthConfiguration(active.baseURL);
    let refreshed = await refreshAuthSession(configuration, active, fetch, migrationProfileID);
    if (accountSessionGeneration !== generation || accountSession !== active) {
      return publicSession(accountSession);
    }
    refreshed = await hydrateAccountSessionAvatar(refreshed);
    await persistAccountSession(refreshed);
    if (accountSessionGeneration !== generation || accountSession !== active) {
      return publicSession(accountSession);
    }
    accountSession = refreshed;
    scheduleAccountSessionRefresh();
    publishAccountSession();
    return publicSession(refreshed);
  })();
  accountSessionRefreshInFlight = refresh;
  try {
    return await refresh;
  } finally {
    if (accountSessionRefreshInFlight === refresh) accountSessionRefreshInFlight = null;
  }
}

function authCallbackFromArguments(argumentsList) {
  return (Array.isArray(argumentsList) ? argumentsList : [])
    .find((value) => typeof value === "string" && value.startsWith("resonance://auth/callback"));
}

async function openAccountSignInBrowser(destination) {
  await shell.openExternal(destination.href);
}

async function handleAccountAuthCallback(value) {
  const pending = pendingAccountSignIn;
  if (!pending || Date.now() - pending.startedAt > 10 * 60_000) {
    pendingAccountSignIn = null;
    throw new Error("The sign-in request expired. Please try again.");
  }
  const callback = new URL(value);
  if (callback.protocol !== "resonance:" || callback.hostname !== "auth" || callback.pathname !== "/callback") {
    throw new Error("The account callback is invalid.");
  }
  if (callback.searchParams.get("state") !== pending.state) {
    throw new Error("The account sign-in state did not match. Please try again.");
  }
  pendingAccountSignIn = null;
  const providerError = callback.searchParams.get("error_description") || callback.searchParams.get("error");
  if (providerError) throw new Error(providerError);
  const code = callback.searchParams.get("code");
  accountSession = await hydrateAccountSessionAvatar(await exchangeAuthCode(
    pending.configuration,
    pending.baseURL,
    code,
    pending.verifier,
    fetch,
    pending.migrationProfileID,
  ));
  await persistAccountSession(accountSession);
  await purgeLegacyServerCredentials();
  scheduleAccountSessionRefresh();
  publishAccountSession();
  return publicSession(accountSession);
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
  Object.defineProperty(controller, "resonanceGeneration", {
    value: ++serverTransferGeneration,
    enumerable: false,
  });
  activeServerTransfers.set(senderID, controller);
  return controller;
}

function serverTransferIsActive(event, controller, generation = controller?.resonanceGeneration) {
  const active = activeServerTransfers.get(event.sender.id);
  return active === controller
    && active?.resonanceGeneration === generation
    && controller?.signal.aborted !== true;
}

function finishServerTransfer(event, controller) {
  if (activeServerTransfers.get(event.sender.id) === controller) activeServerTransfers.delete(event.sender.id);
}

// electron-updater logs to console by default. Packaged GUI launches may inherit
// a short-lived stdout pipe, so a delayed update check can otherwise crash with
// EPIPE after that parent process exits. Status is surfaced through IPC instead.
autoUpdater.logger = null;
autoUpdater.autoDownload = true;
// Never let electron-updater install a downloaded NSIS package before the
// Authenticode publisher check below has completed and the user has opted in.
autoUpdater.autoInstallOnAppQuit = false;

function publishUpdateStatus(type, details = {}) {
  const previousVersion = currentWindowsUpdateStatus.version;
  currentWindowsUpdateStatus = {
    type,
    ...(type !== "current" && (details.version || previousVersion) ? { version: details.version || previousVersion } : {}),
    ...details,
  };
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send("update:status", currentWindowsUpdateStatus);
}

autoUpdater.on("checking-for-update", () => publishUpdateStatus("checking"));
autoUpdater.on("update-available", (information) => {
  verifiedWindowsUpdate = null;
  publishUpdateStatus("available", { version: information.version });
});
autoUpdater.on("update-not-available", () => publishUpdateStatus("current"));
autoUpdater.on("download-progress", (progress) => publishUpdateStatus("downloading", { percent: Math.round(progress.percent || 0) }));
autoUpdater.on("update-downloaded", (information) => {
  windowsUpdateVerificationPromise = (async () => {
    const verification = await verifyDownloadedWindowsUpdate({
      downloadedFile: information?.downloadedFile,
      currentExecutable: process.execPath,
      authenticityMode: windowsPackage.resonanceUpdateAuthenticity,
      packaged: app.isPackaged,
    });
    verifiedWindowsUpdate = Object.freeze({
      version: String(information?.version || ""),
      downloadedFile: String(information?.downloadedFile || ""),
      verification,
    });
    publishUpdateStatus("ready", { version: information.version });
    return verifiedWindowsUpdate;
  })();
  windowsUpdateVerificationPromise.catch((error) => {
    verifiedWindowsUpdate = null;
    publishUpdateStatus("error", { message: conciseUpdaterError(error) });
  }).finally(() => {
    windowsUpdateVerificationPromise = null;
  });
});
autoUpdater.on("error", (error) => {
  verifiedWindowsUpdate = null;
  publishUpdateStatus("error", { message: conciseUpdaterError(error) });
});

async function checkForWindowsUpdates() {
  if (windowsUpdateCheckPromise) return windowsUpdateCheckPromise;
  windowsUpdateCheckPromise = (async () => {
    const { feedURL } = await resolveWindowsUpdateFeed();
    autoUpdater.setFeedURL({ provider: "generic", url: feedURL });
    return autoUpdater.checkForUpdates();
  })();
  try {
    return await windowsUpdateCheckPromise;
  } finally {
    windowsUpdateCheckPromise = null;
  }
}

function runAutomaticUpdateCheck() {
  if (!app.isPackaged || ["available", "downloading", "ready"].includes(currentWindowsUpdateStatus.type)) return;
  void checkForWindowsUpdates().catch((error) => publishUpdateStatus("error", { message: conciseUpdaterError(error) }));
}

function startAutomaticUpdateChecks() {
  if (!app.isPackaged || automaticUpdateCheckTimer || automaticUpdateCheckInterval) return;
  automaticUpdateCheckTimer = setTimeout(() => {
    automaticUpdateCheckTimer = null;
    runAutomaticUpdateCheck();
    automaticUpdateCheckInterval = setInterval(runAutomaticUpdateCheck, AUTOMATIC_UPDATE_CHECK_INTERVAL_MS);
    automaticUpdateCheckInterval.unref?.();
  }, AUTOMATIC_UPDATE_CHECK_DELAY_MS);
  automaticUpdateCheckTimer.unref?.();
}

function applicationPaths() {
  const root = app.getPath("userData");
  return {
    state: path.join(root, "library.json"),
    credentials: path.join(root, "server-credentials.bin"),
    credentialsBackup: path.join(root, "server-credentials.bin.backup"),
    accountSession: path.join(root, "account-session.bin"),
    accountSessionBackup: path.join(root, "account-session.bin.backup"),
    uploadRetries: path.join(root, "server-upload-retries.json"),
    uploadRetriesBackup: path.join(root, "server-upload-retries.json.backup"),
    clientConfigState: path.join(root, "client-config-state.json"),
    clientConfigStateBackup: path.join(root, "client-config-state.json.backup"),
    profilePictures: path.join(root, "ProfilePictures"),
    local: path.join(root, "LocalMusic"),
    remote: path.join(root, "ServerCache"),
  };
}

function boundedText(value, maximumLength = 500) {
  const text = typeof value === "string" ? value.trim() : "";
  return text ? text.slice(0, maximumLength) : null;
}

function canonicalCohortKey(value) {
  const key = typeof value === "string" ? value : "";
  if (!/^[A-Za-z0-9_-]{22}$/.test(key)) return null;
  try {
    const bytes = Buffer.from(key, "base64url");
    return bytes.length === 16 && bytes.toString("base64url") === key ? key : null;
  } catch {
    return null;
  }
}

function safeClientConfigState(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const cohortKey = canonicalCohortKey(value.cohort_key);
  if (!cohortKey) return null;
  const entries = value.entries && typeof value.entries === "object" && !Array.isArray(value.entries)
    ? Object.fromEntries(Object.entries(value.entries).slice(-64).filter(([key, record]) =>
      typeof key === "string"
      && /^client-config-v1-[a-f0-9]{64}$/.test(key)
      && record
      && typeof record === "object"
      && !Array.isArray(record)))
    : {};
  const revisionFloors = value.revision_floors && typeof value.revision_floors === "object" && !Array.isArray(value.revision_floors)
    ? Object.fromEntries(Object.entries(value.revision_floors).filter(([key, revision]) =>
      typeof key === "string"
      && /^client-config-v1-[a-f0-9]{64}$/.test(key)
      && Number.isSafeInteger(revision)
      && revision >= 0))
    : {};
  return { schema_version: 1, cohort_key: cohortKey, entries, revision_floors: revisionFloors };
}

function safeServerTransferPreferences(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const uploadModes = new Set(["local_file", "server_source_link", "reviewed_match"]);
  const downloadModes = new Set(["verified_file_cache", "stream_only"]);
  return Object.fromEntries(Object.entries(value).slice(0, 64).flatMap(([key, preference]) => {
    if (typeof key !== "string" || key.length > 512 || !preference || typeof preference !== "object") return [];
    const separator = key.lastIndexOf("#profile=");
    const serverOrigin = separator > 0 ? normalizedServerOrigin(key.slice(0, separator)) : null;
    const profileID = separator > 0 ? key.slice(separator + "#profile=".length) : "";
    if (!serverOrigin || !profileID || profileID.length > 128 || key !== `${serverOrigin}#profile=${profileID}`) return [];
    return [[key, {
      uploadMode: uploadModes.has(preference.uploadMode) ? preference.uploadMode : "local_file",
      downloadMode: downloadModes.has(preference.downloadMode) ? preference.downloadMode : "verified_file_cache",
    }]];
  }));
}

async function persistClientConfigState() {
  if (!clientConfigState) return;
  const { clientConfigState: destination, clientConfigStateBackup: backupPath } = applicationPaths();
  const snapshot = safeClientConfigState(clientConfigState);
  if (!snapshot) return;
  const save = clientConfigStateSaveQueue
    .catch(() => {})
    .then(() => crashSafeReplaceMirrored(destination, JSON.stringify(snapshot, null, 2), {
      backupPath,
      encoding: "utf8",
      mode: 0o600,
    }));
  clientConfigStateSaveQueue = save;
  await save;
}

function mutateClientConfigState(operation) {
  const pending = clientConfigMutationQueue
    .catch(() => undefined)
    .then(operation);
  clientConfigMutationQueue = pending;
  return pending;
}

async function ensureClientConfigStateLoaded() {
  if (clientConfigState) return clientConfigState;
  if (!clientConfigStateLoadPromise) {
    clientConfigStateLoadPromise = (async () => {
      const { clientConfigState: source, clientConfigStateBackup: backupPath } = applicationPaths();
      try {
        const result = await readPrimaryOrBackup(source, (bytes) => {
          const state = safeClientConfigState(JSON.parse(bytes.toString("utf8")));
          if (!state) throw new Error("Invalid client config state.");
          return state;
        }, { backupPath, mode: 0o600 });
        clientConfigState = result.value;
      } catch (error) {
        if (error?.code !== "ENOENT") console.error("Could not restore the client-config cache", error);
        clientConfigState = {
          schema_version: 1,
          cohort_key: randomBytes(16).toString("base64url"),
          entries: {},
          revision_floors: {},
        };
        await persistClientConfigState();
      }
      return clientConfigState;
    })();
  }
  return clientConfigStateLoadPromise;
}

function safeServerUploadRetryRecord(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const retryID = boundedText(value.retryID, 128);
  const filePath = boundedText(value.filePath, 32_767);
  const serverOrigin = normalizedServerOrigin(value.serverOrigin);
  const createdAt = Number.isFinite(Date.parse(value.createdAt))
    ? new Date(value.createdAt).toISOString()
    : null;
  const recordAge = createdAt ? Date.now() - Date.parse(createdAt) : Number.POSITIVE_INFINITY;
  const mediaSourceURL = preservedMediaSourceURL(value.mediaSourceURL);
  const mediaKind = value.mediaKind === "video" ? "video" : "audio";
  if (!retryID || !filePath || !serverOrigin || !createdAt
      || !mediaSourceURL
      || recordAge < -5 * 60 * 1000
      || recordAge > SERVER_UPLOAD_RETRY_MAX_AGE_MS) return null;
  return {
    retryID,
    filePath: path.resolve(filePath),
    trackID: boundedText(value.trackID, 128),
    title: boundedText(value.title) || path.basename(filePath, path.extname(filePath)),
    artist: boundedText(value.artist),
    album: boundedText(value.album),
    duration: Number.isFinite(Number(value.duration)) && Number(value.duration) >= 0 ? Number(value.duration) : 0,
    artworkURL: safeArtworkURL(value.artworkURL)?.href || null,
    mediaSourceURL,
    mediaKind,
    uploadFilename: safeFilename(value.uploadFilename || path.basename(filePath)),
    serverOrigin,
    profileID: boundedText(value.profileID, 128) || "default",
    createdAt,
  };
}

function sourceLinkRegistrationBody(item, { schemaVersion = 3 } = {}) {
  const sourceURL = transientMediaSourceURL(item.mediaSourceURL);
  if (!sourceURL) {
    throw new Error("Only songs downloaded from a preserved source link can be uploaded. Download this song from its link again first.");
  }
  if (schemaVersion === 2) {
    return JSON.stringify({
      schema_version: 2,
      source_url: sourceURL,
    });
  }
  return JSON.stringify({
    schema_version: 3,
    source_url: sourceURL,
    media_kind: item.mediaKind === "video" ? "video" : "audio",
  });
}

// A resolved provider stream is intentionally usable for the current upload
// request. It is never a durable source of truth and must be removed before a
// retry record, library file, or backup is written.
function transientMediaSourceURL(value) {
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

async function putSourceLinkRegistration({ base, url, headers, item, signal }) {
  const options = (body) => ({
    method: "PUT",
    headers,
    body,
    redirect: "manual",
    signal,
  });
  let response = await fetchSameOrigin(base, url, options(sourceLinkRegistrationBody(item)));
  if (item.mediaKind !== "video" && response.status === 400) {
    const payload = await readResponseJSON(response.clone(), MAX_SOURCE_IMPORT_RESPONSE_BYTES, "Source-link error")
      .catch(() => null);
    if (payload?.error === "Unsupported source-link schema_version") {
      await response.body?.cancel?.().catch(() => undefined);
      response = await fetchSameOrigin(base, url, options(sourceLinkRegistrationBody(item, { schemaVersion: 2 })));
    }
  }
  return response;
}

async function ensureServerUploadRetriesLoaded() {
  if (serverUploadRetryLoadPromise) return serverUploadRetryLoadPromise;
  serverUploadRetryLoadPromise = (async () => {
    const { uploadRetries, uploadRetriesBackup } = await ensureDirectories();
    try {
      const result = await readPrimaryOrBackup(uploadRetries, (bytes) => {
        const payload = JSON.parse(bytes.toString("utf8"));
        if (!Array.isArray(payload)) throw new Error("Invalid upload retry records.");
        return payload;
      }, { backupPath: uploadRetriesBackup });
      for (const value of result.value.slice(-MAX_SERVER_UPLOAD_RETRY_RECORDS)) {
        const record = safeServerUploadRetryRecord(value);
        if (record) serverUploadRetries.set(record.retryID, record);
      }
    } catch (error) {
      if (error?.code !== "ENOENT") console.error("Could not restore server upload retries", error);
    }
  })();
  return serverUploadRetryLoadPromise;
}

async function persistServerUploadRetries() {
  const { uploadRetries, uploadRetriesBackup } = await ensureDirectories();
  const records = [...serverUploadRetries.values()]
    .map(safeServerUploadRetryRecord)
    .filter(Boolean)
    .slice(-MAX_SERVER_UPLOAD_RETRY_RECORDS);
  serverUploadRetries.clear();
  for (const record of records) serverUploadRetries.set(record.retryID, record);
  const save = serverUploadRetrySaveQueue
    .catch(() => {})
    .then(() => crashSafeReplace(
      uploadRetries,
      JSON.stringify(records, null, 2),
      { backupPath: uploadRetriesBackup, encoding: "utf8" },
    ));
  serverUploadRetrySaveQueue = save;
  await save;
}

function safeServerUploadManifests(value) {
  const safeItem = (item) => {
    if (!item || typeof item !== "object" || Array.isArray(item)
        || !["uploaded", "failed", "cancelled"].includes(item.status)) return null;
    return {
      retryID: boundedText(item.retryID, 128),
      trackID: boundedText(item.trackID, 128),
      filename: boundedText(item.filename),
      title: boundedText(item.title) || boundedText(item.filename) || "Untitled song",
      artist: boundedText(item.artist),
      status: item.status,
      attempts: Math.max(0, Math.min(10, Math.floor(Number(item.attempts) || 0))),
      message: item.status === "uploaded" ? null : boundedText(item.message, 1_000),
      remoteID: boundedText(item.remoteID, 128),
    };
  };
  return (Array.isArray(value) ? value : []).flatMap((manifest) => {
    if (!manifest || typeof manifest !== "object" || Array.isArray(manifest)) return [];
    const id = boundedText(manifest.id, 128);
    const serverOrigin = normalizedServerOrigin(manifest.serverOrigin);
    const items = (Array.isArray(manifest.items) ? manifest.items : []).map(safeItem).filter(Boolean).slice(0, MAX_SERVER_UPLOAD_BATCH_FILES);
    if (!id || !serverOrigin || !items.length) return [];
    const startedAt = Number.isFinite(Date.parse(manifest.startedAt))
      ? new Date(manifest.startedAt).toISOString()
      : new Date().toISOString();
    return [{
      id,
      serverOrigin,
      profileID: boundedText(manifest.profileID, 128) || "default",
      source: ["picker", "missing-downloads", "link-import"].includes(manifest.source) ? manifest.source : "picker",
      startedAt,
      updatedAt: Number.isFinite(Date.parse(manifest.updatedAt))
        ? new Date(manifest.updatedAt).toISOString()
        : startedAt,
      items,
    }];
  }).slice(-MAX_SERVER_UPLOAD_MANIFESTS);
}

function safeFilename(value) {
  return sanitizeWindowsFilename(value);
}

function normalizedServerOrigin(value) {
  try {
    const url = new URL(String(value || "").trim());
    return ["https:", "http:"].includes(url.protocol) ? url.origin : null;
  } catch {
    return null;
  }
}

function storageLocationForPath(filePath) {
  if (!filePath) return null;
  const paths = applicationPaths();
  const absolute = path.resolve(String(filePath));
  const local = path.resolve(paths.local);
  const remote = path.resolve(paths.remote);
  if (absolute === local || absolute.startsWith(local + path.sep)) return "local";
  if (absolute === remote || absolute.startsWith(remote + path.sep)) return "server-cache";
  return "external";
}

function isDirectServerCacheFile(filePath) {
  if (typeof filePath !== "string" || !filePath) return false;
  const remote = path.resolve(applicationPaths().remote);
  const candidate = path.resolve(filePath);
  return candidate !== remote && path.dirname(candidate) === remote;
}

async function deleteManagedServerCacheFile(track) {
  if (!track?.filePath) return true;
  if (!isDirectServerCacheFile(track.filePath)) return false;
  try {
    await fs.rm(path.resolve(track.filePath), { force: true });
    return true;
  } catch {
    return false;
  }
}

function safeListeningHistoryArtworkURL(candidate, serverOrigin) {
  const origin = normalizedServerOrigin(serverOrigin);
  if (!origin || typeof candidate !== "string" || candidate.length > 2_048) return null;
  try {
    const url = new URL(candidate, `${origin}/`);
    return url.protocol === "https:" && url.origin === origin && !url.username && !url.password
      ? url.href
      : null;
  } catch {
    return null;
  }
}

function safeListeningHistory(value) {
  const optionalText = (candidate, maximumLength = 500) => {
    const text = typeof candidate === "string" ? candidate.trim() : "";
    return text ? text.slice(0, maximumLength) : null;
  };
  return (Array.isArray(value) ? value : [])
    .filter((entry) =>
      entry
      && typeof entry.id === "string"
      && typeof entry.trackID === "string"
      && entry.id.length <= 128
      && entry.trackID.length <= 128
      && Number.isFinite(Date.parse(entry.startedAt)))
    .map((entry) => {
      const serverOrigin = normalizedServerOrigin(entry.serverOrigin);
      return {
        id: entry.id,
        trackID: entry.trackID,
        profileID: typeof entry.profileID === "string" && entry.profileID ? entry.profileID : "default",
        serverOrigin,
        startedAt: new Date(entry.startedAt).toISOString(),
        listenedSeconds: Math.max(0, Number(entry.listenedSeconds) || 0),
        remoteID: optionalText(entry.remoteID, 128),
        title: optionalText(entry.title),
        artist: optionalText(entry.artist),
        album: optionalText(entry.album),
        duration: entry.duration !== null && entry.duration !== undefined && entry.duration !== ""
          && Number.isFinite(Number(entry.duration)) && Number(entry.duration) >= 0
          ? Math.min(Number(entry.duration), 7 * 24 * 60 * 60)
          : null,
        artworkURL: safeListeningHistoryArtworkURL(entry.artworkURL, serverOrigin),
        originatedOnThisDevice: entry.originatedOnThisDevice !== false,
      };
    })
    .slice(-2000);
}

async function ensureDirectories() {
  const paths = applicationPaths();
  await Promise.all([
    fs.mkdir(paths.local, { recursive: true }),
    fs.mkdir(paths.remote, { recursive: true }),
    fs.mkdir(paths.profilePictures, { recursive: true }),
  ]);
  return paths;
}

function profilePicturePath(serverURL, profileID) {
  const serverOrigin = normalizedServerOrigin(serverURL);
  const profile = String(profileID || "default").trim() || "default";
  if (!serverOrigin || profile.length > 128 || /[\u0000-\u001f\u007f]/.test(profile)) {
    throw new Error("Choose a valid profile before changing its picture.");
  }
  const digest = createHash("sha256")
    .update(`${serverOrigin}#profile=${profile}`, "utf8")
    .digest("hex");
  return path.join(applicationPaths().profilePictures, `${digest}.jpg`);
}

function normalizedProfilePicture(image) {
  if (!image || image.isEmpty()) throw new Error("The selected file is not a supported picture.");
  const size = image.getSize();
  const side = Math.min(size.width, size.height);
  if (!Number.isSafeInteger(side) || side < 1) throw new Error("The selected picture is empty.");
  const square = image.crop({
    x: Math.floor((size.width - side) / 2),
    y: Math.floor((size.height - side) / 2),
    width: side,
    height: side,
  });
  const target = Math.min(side, 512);
  return square.resize({ width: target, height: target, quality: "best" }).toJPEG(88);
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
      candidate = path.join(directory, windowsCollisionFilename(`${base}${extension}`, counter));
      counter += 1;
    } catch {
      return candidate;
    }
  }
}

function publicTrack(filePath, details = {}) {
  const sourceIdentity = normalizeSourceIdentity(details.sourceIdentity, { sourcePageURL: details.sourceURL });
  const sourceIdentities = normalizeSourceIdentities(details.sourceIdentities, sourceIdentity
    ? [sourceIdentity, ...(sourceIdentity.aliases || [])]
    : []);
  let artworkURL = safeArtworkURL(details.artworkURL)?.href || null;
  if (!artworkURL) {
    const sourcePages = [details.sourceURL, sourceIdentity?.sourcePageURL, ...sourceIdentities.map((identity) => identity.sourcePageURL)];
    for (const sourcePage of sourcePages) {
      try {
        const videoID = sourcePage ? youtubeVideoID(sourcePage) : null;
        if (videoID) {
          artworkURL = `https://img.youtube.com/vi/${videoID}/maxresdefault.jpg`;
          break;
        }
      } catch {
        // Source provenance is optional and must not make a stored track unloadable.
      }
    }
  }
  const storedPath = typeof filePath === "string" ? filePath : "";
  return {
    id: details.id || randomUUID(),
    title: details.title || path.basename(filePath, path.extname(filePath)),
    artist: details.artist || "Local file",
    album: details.album || "Unknown Album",
    duration: Number(details.duration) || 0,
    artwork: details.artwork || null,
    artworkURL,
    size: Number(details.size) || 0,
    filePath: storedPath,
    fileUrl: storedPath ? pathToFileURL(storedPath).href : null,
    available: details.available !== false,
    missing: Boolean(details.missing || details.available === false),
    storageLocation: details.storageLocation || storageLocationForPath(filePath),
    remoteID: details.remoteID || null,
    sourceServer: details.sourceServer || null,
    syncProfileID: details.syncProfileID || null,
    remoteModified: details.remoteModified || null,
    sourceURL: sourceIdentity?.sourcePageURL || null,
    sourceIdentity,
    sourceIdentities,
    sourceSha256: details.sourceSha256 || null,
    contentSha256: details.contentSha256 || null,
    preservesUnlinkedImport: typeof details.preservesUnlinkedImport === "boolean"
      ? details.preservesUnlinkedImport
      : null,
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
  return normalizeServerBaseURL(value, { allowInsecureLoopback: !app.isPackaged });
}

function matchesServerOrigin(value, expectedOrigin) {
  if (!value) return false;
  try {
    return new URL(value).origin === expectedOrigin;
  } catch {
    return false;
  }
}

async function authenticatedJSON(url, token, signal) {
  const response = await fetchSameOrigin(url, url, { headers: { Authorization: `Bearer ${token}` }, signal });
  if (!response.ok) throw await serverResponseError(response);
  return readResponseJSON(response, MAX_SERVER_JSON_RESPONSE_BYTES, "Authenticated server response");
}

async function serverResponseError(response) {
  let message = "";
  let body = "";
  const contentType = response.headers.get("content-type")?.toLowerCase() || "";
  try {
    body = await readResponseText(response, MAX_SERVER_ERROR_RESPONSE_BYTES, "Server error response");
  } catch {
    // A malformed or oversized error body must not replace the useful status.
  }
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

function listenAlongTrustedRenderer(owner) {
  const trustedRendererURL = pathToFileURL(path.join(__dirname, "ui", "index.html")).href;
  if (!owner || owner.isDestroyed() || owner.getURL() !== trustedRendererURL) {
    throw new Error("Listen Along is unavailable in this window.");
  }
  return owner;
}

function listenAlongSourceKey(sourceURL) {
  return createHash("sha256").update(String(sourceURL || ""), "utf8").digest("hex");
}

function listenAlongHostToken(value) {
  const token = typeof value === "string" ? value.trim() : "";
  if (!token || token.length > 4_096 || /[\u0000-\u001f\u007f]/.test(token)) {
    throw new ListenAlongValidationError("INVALID_HOST_TOKEN", "The server returned an invalid Listen Along host token.", 502);
  }
  return token;
}

function listenAlongRendererEvent(session, payload) {
  const normalized = normalizeListenAlongResponse(payload, {
    role: session.role,
    fallbackCode: session.code,
    fallbackRevision: session.revision,
  });
  const sourceURL = normalized.snapshot.source_url;
  return Object.freeze({
    ...publicListenAlongEvent({ ...payload, role: session.role }, session.id),
    // The renderer only receives an opaque source key.  The canonical source
    // stays in this main-process session and is used by the resolver below.
    source_key: sourceURL ? listenAlongSourceKey(sourceURL) : null,
    snapshot: Object.freeze({ ...normalized.snapshot, source_url: null }),
  });
}

function listenAlongSessionForOwner(event, sessionID) {
  const id = boundedText(sessionID, 128);
  const session = id ? listenAlongSessions.get(id) : null;
  if (!session || session.ownerWebContentsID !== event.sender.id || session.stopped) {
    throw new Error("The Listen Along session is no longer active.");
  }
  if ((rendererCredentialEpochs.get(event.sender.id) || 0) !== session.credentialEpoch) {
    throw new Error("Listen Along stopped because the server credentials changed.");
  }
  return session;
}

function sendListenAlongStatus(session, state, error = null) {
  const owner = session?.ownerWebContentsID ? webContents.fromId(session.ownerWebContentsID) : null;
  if (!owner || owner.isDestroyed()) return;
  owner.send("listen-along:status", {
    session_id: session.id,
    code: session.code,
    role: session.role,
    state,
    error: error ? String(error.message || error).slice(0, 500) : null,
  });
}

function sendListenAlongEvent(session, payload) {
  const owner = session?.ownerWebContentsID ? webContents.fromId(session.ownerWebContentsID) : null;
  if (!owner || owner.isDestroyed()) return;
  try {
    owner.send("listen-along:event", listenAlongRendererEvent(session, payload));
  } catch (error) {
    sendListenAlongStatus(session, "error", error);
  }
}

function listenAlongRequestSignal(session) {
  const timeout = AbortSignal.timeout(LISTEN_ALONG_REQUEST_TIMEOUT_MS);
  return AbortSignal.any([session.controller.signal, timeout]);
}

async function listenAlongRequestJSON(session, { method = "GET", pathname, body = null, hostToken = null } = {}) {
  const headers = {
    ...profileHeaders(session.token, session.profileID),
    ...(session.clientHeaders || {}),
    Accept: "application/json",
    ...(body === null ? {} : { "Content-Type": "application/json" }),
    ...(hostToken ? { "X-Resonance-Listen-Host": hostToken } : {}),
  };
  let response;
  try {
    response = await fetchSameOrigin(session.base, new URL(pathname, session.base), {
      method,
      headers,
      ...(body === null ? {} : { body: JSON.stringify(body) }),
      redirect: "manual",
      signal: listenAlongRequestSignal(session),
    });
  } catch (error) {
    throw error;
  }
  if (!response.ok) {
    const error = await serverResponseError(response);
    error.status = response.status;
    throw error;
  }
  const rawBody = await boundedResponseBody(response, MAX_LISTEN_ALONG_JSON_BYTES, "Listen Along response");
  if (!rawBody.length) return {};
  try { return JSON.parse(rawBody.toString("utf8")); }
  catch { throw new ListenAlongValidationError("INVALID_RESPONSE", "The server returned invalid Listen Along JSON.", 502); }
}

function clearListenAlongPoll(session) {
  if (session.pollTimer) clearTimeout(session.pollTimer);
  session.pollTimer = null;
}

async function releaseListenAlongMediaSession(capabilityID) {
  const media = listenAlongMediaSessions.get(capabilityID);
  if (!media) return false;
  if (Number(media.leases) > 1) {
    media.leases -= 1;
    return true;
  }
  listenAlongMediaSessions.delete(capabilityID);
  await fs.rm(media.directory, { recursive: true, force: true }).catch(() => undefined);
  return true;
}

async function forceReleaseListenAlongMediaSession(capabilityID) {
  const media = listenAlongMediaSessions.get(capabilityID);
  if (!media) return false;
  listenAlongMediaSessions.delete(capabilityID);
  await fs.rm(media.directory, { recursive: true, force: true }).catch(() => undefined);
  return true;
}

function stopListenAlongSession(sessionID, { state = "left", error = null } = {}) {
  const session = listenAlongSessions.get(sessionID);
  if (!session) return false;
  session.stopped = true;
  clearListenAlongPoll(session);
  if (session.expirationTimer) clearTimeout(session.expirationTimer);
  session.controller.abort();
  for (const [capabilityID, media] of listenAlongMediaSessions) {
    if (media.sessionID === session.id) void forceReleaseListenAlongMediaSession(capabilityID);
  }
  listenAlongSessions.delete(session.id);
  sendListenAlongStatus(session, state, error);
  return true;
}

function stopListenAlongForOwner(ownerWebContentsID, reason = "left") {
  for (const [sessionID, session] of listenAlongSessions) {
    if (session.ownerWebContentsID === ownerWebContentsID) stopListenAlongSession(sessionID, { state: reason });
  }
  for (const [capabilityID, media] of listenAlongMediaSessions) {
    if (media.ownerWebContentsID === ownerWebContentsID) void forceReleaseListenAlongMediaSession(capabilityID);
  }
}

function stopAllListenAlong(reason = "left") {
  for (const sessionID of [...listenAlongSessions.keys()]) stopListenAlongSession(sessionID, { state: reason });
  for (const capabilityID of [...listenAlongMediaSessions.keys()]) void forceReleaseListenAlongMediaSession(capabilityID);
}

function scheduleListenAlongPoll(session, delay = LISTEN_ALONG_POLL_INTERVAL_MS) {
  clearListenAlongPoll(session);
  // The host already receives the authoritative response from every PUT. A
  // background GET would only duplicate traffic; guests are the readers that
  // need the short healthy-room cadence.
  if (session.stopped || session.role !== "guest") return;
  session.pollTimer = setTimeout(() => {
    session.pollTimer = null;
    void pollListenAlongSession(session);
  }, Math.max(250, delay));
  session.pollTimer.unref?.();
}

async function refreshListenAlongSession(session, { emit = true } = {}) {
  const payload = await listenAlongRequestJSON(session, {
    pathname: `api/v1/listen-along/${encodeURIComponent(session.code)}`,
  });
  const normalized = normalizeListenAlongResponse(payload, {
    role: session.role,
    fallbackCode: session.code,
    fallbackRevision: session.revision,
  });
  if (normalized.code !== session.code) {
    throw new ListenAlongValidationError("CODE_MISMATCH", "The server returned a different Listen Along room.", 502);
  }
  const adopted = normalized.revision > session.revision || !session.hasEmittedSnapshot;
  if (adopted) {
    session.revision = normalized.revision;
    session.snapshot = normalized.snapshot;
    session.hasEmittedSnapshot = true;
    if (emit) sendListenAlongEvent(session, payload);
  }
  return { payload, normalized, adopted };
}

function staleListenAlongUpdateResult(session, payload = null) {
  const result = { ok: false, stale: true, revision: session.revision };
  if (!payload) return result;
  try { return { ...result, ...listenAlongRendererEvent(session, payload) }; }
  catch { return result; }
}

async function pollListenAlongSession(session) {
  if (session.stopped || session.pollInFlight) return;
  session.pollInFlight = true;
  try {
    await refreshListenAlongSession(session);
    session.pollBackoff = LISTEN_ALONG_POLL_INTERVAL_MS;
    sendListenAlongStatus(session, "active");
    scheduleListenAlongPoll(session, LISTEN_ALONG_POLL_INTERVAL_MS);
  } catch (error) {
    if (session.stopped) return;
    if (error?.status === 404 || error?.status === 410) {
      stopListenAlongSession(session.id, { state: "ended", error: new Error("The Listen Along room has ended.") });
    } else {
      session.pollBackoff = Math.min(
        LISTEN_ALONG_POLL_MAX_BACKOFF_MS,
        Math.max(LISTEN_ALONG_POLL_INTERVAL_MS, session.pollBackoff * 2),
      );
      sendListenAlongStatus(session, "reconnecting", error);
      scheduleListenAlongPoll(session, session.pollBackoff);
    }
  } finally {
    session.pollInFlight = false;
  }
}

async function resolveListenAlongEphemeralSource(session, sourceURL, mediaKind) {
  if (!localImportEnabled()) throw new Error("Listen Along source playback is disabled in this build.");
  const controller = new AbortController();
  const signal = AbortSignal.any([session.controller.signal, controller.signal, AbortSignal.timeout(5 * 60 * 1000)]);
  const temporaryDirectory = await fs.mkdtemp(path.join(app.getPath("temp"), "resonance-listen-along-"));
  try {
    let metadata = { sourceURL };
    try {
      metadata = await resolveLocalImportMetadata(sourceURL, signal, {}, { mediaKind });
    } catch (error) {
      if (/spotify\.com$/i.test(new URL(sourceURL).hostname)) throw error;
    }
    const preparationContext = JSON.stringify({ listenAlong: session.id, sourceKey: listenAlongSourceKey(sourceURL) });
    const resolution = await resolveLocalImportDownloadSource(
      sourceURL,
      metadata,
      signal,
      () => undefined,
      { searchYouTubeAudioSources },
      { mediaKind, preparationContext },
    );
    const candidate = resolution?.candidates?.[0];
    if (!candidate?.sourceURL) throw new Error("No playable source matched this Listen Along track.");
    const imported = await importConfirmedSource({
      sourceURL: candidate.sourceURL,
      sourceIdentity: candidate.sourceIdentity,
      mediaKind,
      metadata: {
        ...(resolution.track || {}),
        ...(metadata || {}),
        sourceURL,
      },
      preparedSoundCloudAudio: candidate.preparedSoundCloudAudio,
      preparationContext,
      existing: [],
      destinationDirectory: temporaryDirectory,
      temporaryRoot: app.getPath("temp"),
    }, signal);
    if (imported.kind !== "created" || !imported.filePath) throw new Error("The Listen Along source did not produce playable media.");
    const info = await fs.stat(imported.filePath);
    return {
      directory: temporaryDirectory,
      filePath: imported.filePath,
      fileUrl: pathToFileURL(imported.filePath).href,
      size: Number(info.size) || 0,
      title: boundedText(imported.metadata?.title || metadata?.title || resolution.track?.title, 500) || "Untitled",
      artist: boundedText(imported.metadata?.artist || metadata?.artist || resolution.track?.artist, 500) || "Unknown Artist",
      album: boundedText(imported.metadata?.album || metadata?.album || resolution.track?.album, 500) || "Listen Along",
      duration: Number(imported.metadata?.durationSeconds || metadata?.durationSeconds || resolution.track?.durationSeconds) || 0,
      artworkURL: safeArtworkURL(imported.metadata?.artworkURL || metadata?.artworkURL || resolution.track?.artworkURL)?.href || null,
    };
  } catch (error) {
    await fs.rm(temporaryDirectory, { recursive: true, force: true }).catch(() => undefined);
    throw error;
  } finally {
    controller.abort();
  }
}

async function createListenAlongSession(event, settings, role) {
  const owner = listenAlongTrustedRenderer(event.sender);
  const token = canonicalStreamCredential(settings.token);
  const profileID = canonicalStreamProfileID(settings.profileID);
  const base = canonicalStreamBaseURL(settings.baseURL);
  const credentialEpoch = rendererCredentialEpochs.get(owner.id) || 0;
  stopListenAlongForOwner(owner.id, "replaced");
  const session = {
    id: randomUUID(),
    ownerWebContentsID: owner.id,
    role,
    base,
    token,
    profileID,
    credentialEpoch,
    code: null,
    hostToken: null,
    revision: 0,
    snapshot: null,
    clientHeaders: {},
    controller: new AbortController(),
    pollTimer: null,
    pollBackoff: LISTEN_ALONG_POLL_INTERVAL_MS,
    pollInFlight: false,
    hasEmittedSnapshot: false,
    stopped: false,
    createdAt: Date.now(),
    expirationTimer: null,
  };
  session.clientHeaders = (await clientConfigContext(base.href, profileID)).expected.request_headers;
  let payload;
  if (role === "host") {
    const snapshot = canonicalListenAlongSnapshot(settings.snapshot || settings, { sourceRequired: true });
    payload = await listenAlongRequestJSON(session, {
      method: "POST",
      pathname: "api/v1/listen-along",
      body: {
        source_url: snapshot.source_url,
        media_kind: snapshot.media_kind,
        position_seconds: snapshot.position_seconds,
        is_playing: snapshot.is_playing,
      },
    });
  } else {
    const code = canonicalListenAlongCode(settings.code);
    session.code = code;
    payload = await listenAlongRequestJSON(session, { pathname: `api/v1/listen-along/${encodeURIComponent(code)}` });
  }
  const normalized = normalizeListenAlongResponse(payload, {
    role,
    fallbackCode: session.code,
    fallbackRevision: 0,
  });
  if (normalized.role !== role) {
    throw new ListenAlongValidationError("ROLE_MISMATCH", "The server returned an invalid Listen Along role.", 502);
  }
  if (role === "host") session.hostToken = listenAlongHostToken(payload.host_token ?? payload.hostToken);
  session.code = normalized.code;
  session.revision = normalized.revision;
  session.snapshot = normalized.snapshot;
  session.hasEmittedSnapshot = true;
  session.expirationTimer = setTimeout(() => stopListenAlongSession(session.id, {
    state: "ended",
    error: new Error("The Listen Along room expired."),
  }), LISTEN_ALONG_SESSION_TTL_MS);
  session.expirationTimer.unref?.();
  listenAlongSessions.set(session.id, session);
  sendListenAlongEvent(session, payload);
  sendListenAlongStatus(session, "active");
  scheduleListenAlongPoll(session);
  return listenAlongRendererEvent(session, payload);
}

ipcMain.handle("listen-along:create", async (event, settings = {}) => createListenAlongSession(event, settings, "host"));
ipcMain.handle("listen-along:join", async (event, settings = {}) => createListenAlongSession(event, settings, "guest"));

ipcMain.handle("listen-along:update", async (event, settings = {}) => {
  const session = listenAlongSessionForOwner(event, settings.sessionID);
  if (session.role !== "host" || !session.hostToken) throw new Error("Only the Listen Along host can update playback.");
  const requestedRevision = canonicalListenAlongRevision(settings.revision, { fallback: session.revision });
  if (requestedRevision !== session.revision) {
    let refreshed = null;
    try {
      refreshed = await refreshListenAlongSession(session);
    } catch (error) {
      sendListenAlongStatus(session, "reconnecting", error);
      scheduleListenAlongPoll(session, 0);
    }
    sendListenAlongStatus(session, "stale", new Error("Listen Along changed elsewhere; refreshing the current room."));
    return staleListenAlongUpdateResult(session, refreshed?.payload);
  }
  const snapshot = canonicalListenAlongSnapshot(settings.snapshot || settings, { sourceRequired: false });
  let payload = null;
  let putRevision = requestedRevision;
  let conflictRetry = false;
  while (!payload) {
    try {
      payload = await listenAlongRequestJSON(session, {
        method: "PUT",
        pathname: `api/v1/listen-along/${encodeURIComponent(session.code)}`,
        hostToken: session.hostToken,
        body: { revision: putRevision, ...snapshot },
      });
    } catch (error) {
      if (error?.status !== 409 || conflictRetry) {
        if (error?.status === 409) {
          let refreshed = null;
          try { refreshed = await refreshListenAlongSession(session); }
          catch (refreshError) {
            sendListenAlongStatus(session, "reconnecting", refreshError);
            scheduleListenAlongPoll(session, 0);
          }
          sendListenAlongStatus(session, "stale", new Error("Listen Along changed elsewhere; refreshing the current room."));
          return staleListenAlongUpdateResult(session, refreshed?.payload);
        }
        throw error;
      }
      conflictRetry = true;
      let refreshed;
      try {
        refreshed = await refreshListenAlongSession(session);
      } catch (refreshError) {
        sendListenAlongStatus(session, "reconnecting", refreshError);
        scheduleListenAlongPoll(session, 0);
        sendListenAlongStatus(session, "stale", new Error("Listen Along changed elsewhere; refreshing the current room."));
        return staleListenAlongUpdateResult(session);
      }
      if (!refreshed.adopted) {
        sendListenAlongStatus(session, "stale", new Error("Listen Along changed elsewhere; refreshing the current room."));
        return staleListenAlongUpdateResult(session, refreshed.payload);
      }
      putRevision = session.revision;
    }
  }
  const normalized = normalizeListenAlongResponse(payload, {
    role: "host",
    fallbackCode: session.code,
    fallbackRevision: requestedRevision + 1,
  });
  session.revision = normalized.revision;
  session.snapshot = normalized.snapshot;
  sendListenAlongEvent(session, payload);
  return { ok: true, ...listenAlongRendererEvent(session, payload) };
});

ipcMain.handle("listen-along:leave", async (event, settings = {}) => {
  const session = listenAlongSessionForOwner(event, settings.sessionID);
  let error = null;
  if (session.role === "host" && session.hostToken) {
    try {
      await listenAlongRequestJSON(session, {
        method: "DELETE",
        pathname: `api/v1/listen-along/${encodeURIComponent(session.code)}`,
        hostToken: session.hostToken,
      });
    } catch (requestError) {
      error = requestError;
    }
  }
  stopListenAlongSession(session.id, { state: "left", error });
  if (error && error.status !== 404 && error.status !== 410) throw error;
  return true;
});

ipcMain.handle("listen-along:source:create", async (event, settings = {}) => {
  const session = listenAlongSessionForOwner(event, settings.sessionID);
  if (session.role !== "guest") throw new Error("Only a Listen Along guest needs a source capability.");
  const sourceURL = session.snapshot?.source_url;
  const sourceKey = boundedText(settings.sourceKey, 128);
  if (!sourceURL || !sourceKey || sourceKey !== listenAlongSourceKey(sourceURL)) {
    throw new Error("The Listen Along source is no longer current.");
  }
  const mediaKind = canonicalListenAlongMediaKind(settings.mediaKind || session.snapshot.media_kind);
  if (mediaKind !== session.snapshot.media_kind) throw new Error("The Listen Along media kind changed.");
  for (const media of listenAlongMediaSessions.values()) {
    if (media.sessionID === session.id && media.sourceKey === sourceKey) {
      // Each IPC caller receives one lease. This matters when a newer host
      // revision arrives while an older apply is still awaiting the same
      // provider resolution: the older apply may release its lease without
      // deleting the file owned by the newer apply.
      media.leases = Number(media.leases) > 0 ? media.leases + 1 : 1;
      return {
        url: media.fileUrl,
        capabilityID: media.capabilityID,
        title: media.title,
        artist: media.artist,
        album: media.album,
        duration: media.duration,
        artworkURL: media.artworkURL,
        mediaKind,
      };
    }
  }
  // A pause, seek, or play update can arrive while a new source is still
  // being prepared. Reuse the in-flight capability instead of starting a
  // second provider resolution/download for the same source.
  const pendingKey = `${session.id}:${sourceKey}`;
  const pending = listenAlongMediaPending.get(pendingKey);
  if (pending) {
    // Reserve the second lease before the shared operation can resolve. The
    // older renderer apply is then free to release its lease without racing
    // the newer apply's first use of the same capability file.
    pending.waiters += 1;
    return pending.promise;
  }
  const pendingRecord = { promise: null, waiters: 0 };
  const operation = (async () => {
    sendListenAlongStatus(session, "resolving");
    const resolved = await resolveListenAlongEphemeralSource(session, sourceURL, mediaKind);
    if (session.stopped) {
      await fs.rm(resolved.directory, { recursive: true, force: true }).catch(() => undefined);
      throw new Error("The Listen Along session is no longer active.");
    }
    const ownedMedia = [...listenAlongMediaSessions.entries()]
      .filter(([, media]) => media.sessionID === session.id)
      .sort((left, right) => left[1].createdAt - right[1].createdAt);
    while (ownedMedia.length >= MAX_LISTEN_ALONG_MEDIA_SESSIONS_PER_SESSION) {
      const oldest = ownedMedia.shift();
      if (oldest) await releaseListenAlongMediaSession(oldest[0]);
    }
    const capabilityID = randomBytes(32).toString("hex");
    const media = {
      capabilityID,
      sessionID: session.id,
      ownerWebContentsID: event.sender.id,
      sourceKey,
      mediaKind,
      leases: 1 + pendingRecord.waiters,
      createdAt: Date.now(),
      ...resolved,
      fileUrl: resolved.fileUrl,
    };
    listenAlongMediaSessions.set(capabilityID, media);
    sendListenAlongStatus(session, "active");
    return {
      url: resolved.fileUrl,
      capabilityID,
      mediaKind,
      title: media.title,
      artist: media.artist,
      album: media.album,
      duration: media.duration,
      artworkURL: media.artworkURL,
    };
  })();
  pendingRecord.promise = operation;
  listenAlongMediaPending.set(pendingKey, pendingRecord);
  try {
    return await operation;
  } finally {
    if (listenAlongMediaPending.get(pendingKey) === pendingRecord) listenAlongMediaPending.delete(pendingKey);
  }
});

ipcMain.handle("listen-along:source:release", async (event, value) => {
  const capabilityID = boundedText(value?.capabilityID, 128);
  const media = capabilityID ? listenAlongMediaSessions.get(capabilityID) : null;
  if (!media || media.ownerWebContentsID !== event.sender.id) return false;
  return releaseListenAlongMediaSession(capabilityID);
});

ipcMain.handle("listen-along:copy-code", (event, value) => {
  listenAlongTrustedRenderer(event.sender);
  const code = canonicalListenAlongCode(value);
  clipboard.writeText(code);
  return { copied: true };
});

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
  const trustedRendererURL = pathToFileURL(path.join(__dirname, "ui", "index.html")).href;
  const window = new BrowserWindow({
    width: 1360,
    height: 850,
    minWidth: 980,
    minHeight: 650,
    backgroundColor: "#05060a",
    title: resonanceApplicationName,
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
  window.on("page-title-updated", (event) => {
    event.preventDefault();
    window.setTitle(resonanceApplicationName);
  });
  window.resonanceCloseReady = false;
  window.resonanceCloseRequested = false;
  window.resonanceCloseTimer = null;
  window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  window.webContents.on("will-navigate", (event, targetURL) => {
    if (targetURL !== trustedRendererURL) event.preventDefault();
  });
  window.webContents.on("will-attach-webview", (event) => event.preventDefault());
  const windowWebContentsID = window.webContents.id;
  window.webContents.once("destroyed", () => {
    revokeServerStreamsForOwner(windowWebContentsID);
    stopListenAlongForOwner(windowWebContentsID, "window_closed");
    serverCatalogSnapshots.clear(windowWebContentsID);
    rendererCredentialFingerprints.delete(windowWebContentsID);
    rendererCredentialEpochs.delete(windowWebContentsID);
  });
  window.on("close", (event) => {
    if (runtimeAppPreferences.runInBackground && !applicationQuitRequested) {
      event.preventDefault();
      window.hide();
      ensureBackgroundTray();
      return;
    }
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

function safeAppPreferences(value) {
  const preferences = value && typeof value === "object" && !Array.isArray(value) ? value : {};
  const keybinds = preferences.keybinds && typeof preferences.keybinds === "object" && !Array.isArray(preferences.keybinds)
    ? preferences.keybinds
    : {};
  const defaults = {
    togglePlayback: "Space",
    previousTrack: "Ctrl+ArrowLeft",
    nextTrack: "Ctrl+ArrowRight",
    volumeDown: "Ctrl+ArrowDown",
    volumeUp: "Ctrl+ArrowUp",
  };
  const requestedCrossfadeSeconds = Number(preferences.crossfadeSeconds);
  return {
    theme: typeof preferences.theme === "string" && APP_THEME_IDS.has(preferences.theme)
      ? preferences.theme
      : DEFAULT_APP_THEME,
    runInBackground: Boolean(preferences.runInBackground),
    discordRichPresence: Boolean(preferences.discordRichPresence),
    crossfadeEnabled: Boolean(preferences.crossfadeEnabled),
    crossfadeSeconds: Number.isFinite(requestedCrossfadeSeconds)
      ? Math.max(1, Math.min(12, Math.round(requestedCrossfadeSeconds)))
      : 5,
    keybinds: Object.fromEntries(Object.entries(defaults).map(([action, fallback]) => {
      const candidate = typeof keybinds[action] === "string" ? keybinds[action].trim().slice(0, 80) : "";
      return [action, candidate || fallback];
    })),
  };
}

function safeRemoteSongMetadataCache(value, now = Date.now()) {
  const cutoff = now - REMOTE_SONG_METADATA_CACHE_MAX_AGE_MS;
  const entries = [];
  if (value && typeof value === "object" && !Array.isArray(value)) {
    for (const item of Object.values(value)) {
      if (!item || typeof item !== "object" || Array.isArray(item)) continue;
      const sourceURL = preservedMediaSourceURL(item.sourceURL);
      const mediaKind = item.mediaKind === "video" ? "video" : "audio";
      const title = boundedText(item.title, 500);
      const artist = boundedText(item.artist, 500);
      const cachedAtTime = Date.parse(item.cachedAt);
      if (!sourceURL || !title || !artist || !Number.isFinite(cachedAtTime) || cachedAtTime < cutoff) continue;
      const duration = Number(item.duration);
      entries.push([`${mediaKind}:${sourceURL}`, {
        sourceURL,
        mediaKind,
        title,
        artist,
        album: boundedText(item.album, 500),
        duration: Number.isFinite(duration) && duration > 0 ? duration : null,
        artworkURL: safeArtworkURL(item.artworkURL)?.href || null,
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
    if (normalizedCount >= MAX_REMOTE_SONG_METADATA_CACHE_RECORDS) break;
  }
  return normalized;
}

function showMainWindow() {
  if (!mainWindow || mainWindow.isDestroyed()) {
    createWindow();
    return;
  }
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.show();
  mainWindow.focus();
}

function ensureBackgroundTray() {
  if (backgroundTray || !app.isReady()) return backgroundTray;
  const trayIcon = process.platform === "darwin"
    ? nativeImage.createFromNamedImage("NSImageNameAudioOutputVolumeHighTemplate")
    : path.join(__dirname, "resonance.ico");
  backgroundTray = new Tray(trayIcon);
  backgroundTray.setToolTip("Resonance");
  backgroundTray.setContextMenu(Menu.buildFromTemplate([
    { label: "Open Resonance", click: showMainWindow },
    { type: "separator" },
    {
      label: "Quit Resonance",
      click: () => {
        applicationQuitRequested = true;
        app.quit();
      },
    },
  ]));
  backgroundTray.on("click", showMainWindow);
  return backgroundTray;
}

ipcMain.handle("app:preferences:update", (_event, value) => {
  runtimeAppPreferences = safeAppPreferences(value);
  if (runtimeAppPreferences.runInBackground) ensureBackgroundTray();
  else if (backgroundTray) {
    backgroundTray.destroy();
    backgroundTray = null;
  }
  currentDiscordPresenceStatus = discordRPC.configure({
    enabled: runtimeAppPreferences.discordRichPresence,
    applicationID: bundledDiscordApplicationID,
  });
  return runtimeAppPreferences;
});

ipcMain.handle("app:discord-presence:update", (_event, value) => {
  currentDiscordPresenceStatus = discordRPC.setActivity(value);
  return currentDiscordPresenceStatus;
});

ipcMain.handle("app:discord-presence:status", () => discordRPC.status());

app.on("before-quit", () => {
  applicationQuitRequested = true;
  discordRPC.destroy();
  if (backgroundTray) {
    backgroundTray.destroy();
    backgroundTray = null;
  }
  revokeAllServerStreams();
  if (automaticUpdateCheckTimer) clearTimeout(automaticUpdateCheckTimer);
  if (automaticUpdateCheckInterval) clearInterval(automaticUpdateCheckInterval);
  automaticUpdateCheckTimer = null;
  automaticUpdateCheckInterval = null;
  if (accountSessionRefreshTimer) clearTimeout(accountSessionRefreshTimer);
  accountSessionRefreshTimer = null;
  pendingAccountSignIn = null;
});

const hasSingleInstanceLock = app.requestSingleInstanceLock();
if (!hasSingleInstanceLock) app.quit();

if (process.platform === "win32") {
  if (process.defaultApp && process.argv[1]) {
    app.setAsDefaultProtocolClient("resonance", process.execPath, [path.resolve(process.argv[1])]);
  } else {
    app.setAsDefaultProtocolClient("resonance");
  }
} else if (process.platform === "darwin" && !app.isPackaged) {
  app.setAsDefaultProtocolClient("resonance");
}

app.on("second-instance", (_event, commandLine) => {
  showMainWindow();
  const callback = authCallbackFromArguments(commandLine);
  if (callback) void handleAccountAuthCallback(callback).catch(publishAccountSession);
});

app.on("open-url", (event, value) => {
  if (!String(value || "").startsWith("resonance://auth/callback")) return;
  event.preventDefault();
  void handleAccountAuthCallback(value).catch(publishAccountSession);
});

app.whenReady().then(async () => {
  if (!hasSingleInstanceLock) return;
  await cleanupLocalImportTemporaryFiles();
  await ensureDirectories();
  protocol.handle(SERVER_STREAM_SCHEME, handleServerStreamRequest);
  createWindow();
  startAutomaticUpdateChecks();
  const startupCallback = authCallbackFromArguments(process.argv);
  if (startupCallback) void handleAccountAuthCallback(startupCallback).catch(publishAccountSession);
  app.on("activate", () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});

// This is the Windows client even when it is previewed from macOS. Closing its
// only window should terminate the preview instead of leaving a hidden process
// that can recreate the window on activation.
app.on("window-all-closed", () => app.quit());
app.on("before-quit", () => {
  applicationQuitRequested = true;
  stopAllListenAlong("app_closed");
});

ipcMain.handle("update:check", async () => {
  if (!app.isPackaged) return { supported: false };
  await checkForWindowsUpdates();
  return { supported: true };
});

ipcMain.handle("update:state", () => currentWindowsUpdateStatus);

ipcMain.handle("update:install", () => {
  if (!app.isPackaged) return false;
  if (!verifiedWindowsUpdate || windowsUpdateVerificationPromise) return false;
  // The assisted NSIS UI is useful for a first install, but an update already
  // knows the existing install directory. Apply it silently and relaunch the
  // app so upgrading never sends the user back through setup.
  return installDownloadedWindowsUpdate(autoUpdater);
});

function persistableLibraryTrack(track) {
  return Boolean(track
    && typeof track === "object"
    && track.transientStream !== true
    && !(typeof track.id === "string" && track.id.startsWith("stream:"))
    && !(typeof track.fileUrl === "string" && track.fileUrl.startsWith(`${SERVER_STREAM_SCHEME}:`)));
}

function sanitizePersistentPlaybackReferences(value, persistentTrackIDs) {
  value.currentTrackID = persistentTrackIDs.has(value.currentTrackID) ? value.currentTrackID : null;
  value.playbackQueueIDs = Array.isArray(value.playbackQueueIDs)
    ? value.playbackQueueIDs.filter((id) => persistentTrackIDs.has(id))
    : [];
  value.playbackSourceQueueIDs = Array.isArray(value.playbackSourceQueueIDs)
    ? value.playbackSourceQueueIDs.filter((id) => persistentTrackIDs.has(id))
    : [];
  value.favorites = Array.isArray(value.favorites) ? value.favorites.filter((id) => persistentTrackIDs.has(id)) : [];
  value.playlists = Array.isArray(value.playlists) ? value.playlists.map((playlist) => ({
    ...playlist,
    trackIDs: Array.isArray(playlist?.trackIDs) ? playlist.trackIDs.filter((id) => persistentTrackIDs.has(id)) : [],
  })) : [];
  value.listeningHistory = safeListeningHistory(value.listeningHistory)
    .filter((entry) => typeof entry.trackID !== "string" || !entry.trackID.startsWith("stream:"));
  return value;
}

ipcMain.handle("library:load", async () => {
  const { state } = await ensureDirectories();
  try {
    let stored = JSON.parse(await fs.readFile(state, "utf8"));
    const migration = await migrateUnlinkedDownloads(stored, {
      legacyDownloadOwned: (track) => isDirectServerCacheFile(track?.filePath),
      deleteManagedDownload: deleteManagedServerCacheFile,
    });
    stored = migration.state;
    const storedTracks = Array.isArray(stored.tracks) ? stored.tracks.filter(persistableLibraryTrack) : [];
    const localUploadSizes = new Set(storedTracks
      .filter((track) => !track?.remoteID && track?.contentSha256 && Number.isFinite(Number(track?.size)))
      .map((track) => Number(track.size)));
    const tracks = await Promise.all(storedTracks.map(async (track) => {
      if (!track.filePath) {
        return publicTrack("", { ...track, available: false, missing: true, storageLocation: null });
      }
      try {
        const information = await fs.stat(track.filePath);
        if (!information.isFile()) throw Object.assign(new Error("The stored path is not a file."), { code: "ENOENT" });
        const contentSha256 = track.contentSha256
          || (track.remoteID && localUploadSizes.has(information.size) ? await fileSHA256(track.filePath) : null);
        return enrichedTrack(track.filePath, {
          ...track,
          size: information.size,
          contentSha256,
          available: true,
          missing: false,
          storageLocation: storageLocationForPath(track.filePath),
        });
      } catch {
        return publicTrack(track.filePath, {
          ...track,
          available: false,
          missing: true,
          storageLocation: storageLocationForPath(track.filePath),
        });
      }
    }));
    stored.tracks = tracks.map((track) => {
      const sourceIdentity = sanitizePersistedSourceIdentity(track.sourceIdentity, { sourcePageURL: track.sourceURL });
      const sourceIdentities = sanitizePersistedSourceIdentities(track.sourceIdentities, sourceIdentity
        ? [sourceIdentity, ...(sourceIdentity.aliases || [])]
        : []);
      return {
        ...track,
        sourceURL: sourceIdentity?.sourcePageURL || null,
        sourceIdentity,
        sourceIdentities,
      };
    });
    sanitizePersistentPlaybackReferences(stored, new Set(tracks.map((track) => track.id).filter(Boolean)));
    stored.serverUploadManifests = safeServerUploadManifests(stored.serverUploadManifests);
    stored.serverTransferPreferences = safeServerTransferPreferences(stored.serverTransferPreferences);
    stored.remoteSongMetadataCache = safeRemoteSongMetadataCache(stored.remoteSongMetadataCache);
    await atomicWriteFile(state, JSON.stringify({
      ...stored,
      tracks: stored.tracks.map(({ fileUrl, ...track }) => track),
    }, null, 2), "utf8");
    return { state: stored, warning: null };
  } catch (error) {
    if (error?.code === "ENOENT") {
      return { state: { completedMigrations: [UNLINKED_DOWNLOAD_MIGRATION_ID] }, warning: null };
    }
    const backup = `${state}.corrupt-${Date.now()}`;
    let warning = "Resonance could not read your saved library. A new empty library was opened.";
    let backupWritten = false;
    try {
      const rawBackup = JSON.parse(await fs.readFile(state, "utf8"));
      await atomicWriteFile(backup, JSON.stringify(sanitizePersistedJSON(rawBackup), null, 2), "utf8");
      backupWritten = true;
    } catch { /* the original read error remains the useful failure */ }
    if (backupWritten) warning += ` The unreadable file was preserved as ${path.basename(backup)} after removing short-lived provider URLs.`;
    else warning += " The unreadable file was not copied because it may contain short-lived provider URLs.";
    return { state: null, warning };
  }
});

ipcMain.handle("library:save", async (_event, state) => {
  const paths = await ensureDirectories();
  const tracks = Array.isArray(state.tracks) ? state.tracks.filter(persistableLibraryTrack) : [];
  const persistentTrackIDs = new Set(tracks.map((track) => track.id).filter(Boolean));
  const safeState = {
    tracks: tracks.map(({ fileUrl, transientStream, ...track }) => {
      const sourceIdentity = sanitizePersistedSourceIdentity(track.sourceIdentity, { sourcePageURL: track.sourceURL });
      const sourceIdentities = sanitizePersistedSourceIdentities(track.sourceIdentities, sourceIdentity
        ? [sourceIdentity, ...(sourceIdentity.aliases || [])]
        : []);
      return {
        ...track,
        sourceURL: sourceIdentity?.sourcePageURL || null,
        sourceIdentity,
        sourceIdentities,
        available: track.available !== false,
        missing: Boolean(track.missing || track.available === false),
        storageLocation: storageLocationForPath(track.filePath) || track.storageLocation || null,
      };
    }),
    playlists: Array.isArray(state.playlists) ? state.playlists.map((playlist) => ({
      ...playlist,
      trackIDs: Array.isArray(playlist?.trackIDs) ? playlist.trackIDs.filter((id) => persistentTrackIDs.has(id)) : [],
    })) : [],
    favorites: Array.isArray(state.favorites) ? state.favorites.filter((id) => persistentTrackIDs.has(id)) : [],
    serverURL: typeof state.serverURL === "string" ? state.serverURL : "",
    volume: Number.isFinite(state.volume) ? state.volume : 0.78,
    playbackRate: Number.isFinite(state.playbackRate) ? state.playbackRate : 1,
    shuffle: Boolean(state.shuffle),
    repeat: Boolean(state.repeat),
    currentTrackID: persistentTrackIDs.has(state.currentTrackID) ? state.currentTrackID : null,
    position: Number.isFinite(state.position) ? state.position : 0,
    playbackQueueIDs: Array.isArray(state.playbackQueueIDs) ? state.playbackQueueIDs.filter((id) => persistentTrackIDs.has(id)) : [],
    playbackSourceQueueIDs: Array.isArray(state.playbackSourceQueueIDs) ? state.playbackSourceQueueIDs.filter((id) => persistentTrackIDs.has(id)) : [],
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
    listeningHistory: safeListeningHistory(state.listeningHistory)
      .filter((entry) => typeof entry.trackID !== "string" || !entry.trackID.startsWith("stream:")),
    serverUploadManifests: safeServerUploadManifests(state.serverUploadManifests),
    serverTransferPreferences: safeServerTransferPreferences(state.serverTransferPreferences),
    remoteSongMetadataCache: safeRemoteSongMetadataCache(state.remoteSongMetadataCache),
    appPreferences: safeAppPreferences(state.appPreferences),
    completedMigrations: Array.isArray(state.completedMigrations)
      ? state.completedMigrations.filter((item) => typeof item === "string" && item.length <= 100)
      : [],
  };
  const save = librarySaveQueue
    .catch(() => {})
    .then(() => atomicWriteFile(paths.state, JSON.stringify(safeState, null, 2), "utf8"));
  librarySaveQueue = save;
  await save;
  return true;
});

ipcMain.handle("library:refresh-metadata", async (_event, value) => {
  const paths = await ensureDirectories();
  const managedRoots = [paths.local, paths.remote];
  const requested = Array.isArray(value) ? value.slice(0, 5_000) : [];
  const results = [];
  for (const item of requested) {
    const id = boundedText(item?.id, 200);
    const filePath = typeof item?.filePath === "string" ? path.resolve(item.filePath) : "";
    if (!id || !filePath || !isManagedLibraryFile(filePath, managedRoots)) continue;
    try {
      const information = await fs.stat(filePath);
      if (!information.isFile()) continue;
      results.push({ id, metadata: await readAudioMetadata(filePath) });
    } catch {
      // A missing or unreadable file does not prevent the remaining library from refreshing.
    }
  }
  return results;
});

ipcMain.handle("library:video-frames", async (_event, value = {}) => {
  const filePath = path.resolve(String(value.filePath || ""));
  const duration = Math.max(0, Math.min(Number(value.duration) || 0, 7 * 24 * 60 * 60));
  const count = Math.max(1, Math.min(Math.floor(Number(value.count) || 12), 12));
  const paths = applicationPaths();
  const managedRoots = [paths.local, paths.remote];
  if (!VIDEO_EXTENSIONS.has(path.extname(filePath).toLowerCase())
      || !isManagedLibraryFile(filePath, managedRoots)) {
    throw new Error("Video thumbnails are limited to installed Resonance videos.");
  }
  const information = await fs.stat(filePath);
  if (!information.isFile() || !duration) throw new Error("The video is unavailable.");
  const frames = [];
  for (let index = 0; index < count; index += 1) {
    const seconds = Math.min(duration * (index + 0.5) / count, Math.max(duration - 0.02, 0));
    frames.push(await captureVideoFrame(filePath, seconds));
  }
  return frames;
});

function credentialFingerprint(value) {
  const { clientToken, adminToken } = canonicalServerCredentials(value);
  return createHmac("sha256", credentialFingerprintKey)
    .update(`${Buffer.byteLength(clientToken, "utf8")}:`, "utf8")
    .update(clientToken, "utf8")
    .update(`${Buffer.byteLength(adminToken, "utf8")}:`, "utf8")
    .update(adminToken, "utf8")
    .digest("hex");
}

function serverCatalogCredentialFingerprint(token) {
  const value = canonicalCredentialToken(token);
  return createHmac("sha256", credentialFingerprintKey)
    .update(`${Buffer.byteLength(value, "utf8")}:`, "utf8")
    .update(value, "utf8")
    .digest("hex");
}

ipcMain.handle("server:credentials:load", async (event) => {
  let rawValue = { clientToken: "", adminToken: "" };
  if (usesPreviewCredentialStore()) {
    rawValue = await readPreviewCredentials();
  } else {
    const { credentials, credentialsBackup } = await ensureDirectories();
    const safeStorage = encryptedCredentialStorage();
    if (safeStorage.isEncryptionAvailable()) {
      try {
        const result = await readPrimaryOrBackup(credentials, (encrypted) => {
          const parsed = JSON.parse(safeStorage.decryptString(encrypted));
          return {
            clientToken: String(parsed?.clientToken || ""),
            adminToken: String(parsed?.adminToken || ""),
          };
        }, { backupPath: credentialsBackup });
        rawValue = result.value;
      } catch {
        // Missing or invalid credentials remain empty.
      }
    }
  }
  let value;
  let canMigrate = true;
  try { value = canonicalServerCredentials(rawValue); }
  catch {
    value = { clientToken: "", adminToken: "" };
    canMigrate = false;
  }
  if (canMigrate && (value.clientToken !== rawValue.clientToken || value.adminToken !== rawValue.adminToken)) {
    await persistServerCredentials(value).catch(() => undefined);
  }
  rendererCredentialFingerprints.set(event.sender.id, credentialFingerprint(value));
  if (!rendererCredentialEpochs.has(event.sender.id)) rendererCredentialEpochs.set(event.sender.id, 0);
  return value;
});

ipcMain.handle("server:credentials:save", async (event, value) => {
  const credentialsValue = canonicalServerCredentials(value);
  const previousFingerprint = rendererCredentialFingerprints.get(event.sender.id);
  const nextFingerprint = credentialFingerprint(credentialsValue);
  await persistServerCredentials(credentialsValue);
  if (previousFingerprint !== nextFingerprint) {
    rendererCredentialEpochs.set(event.sender.id, (rendererCredentialEpochs.get(event.sender.id) || 0) + 1);
    revokeServerStreamsForOwner(event.sender.id);
    stopListenAlongForOwner(event.sender.id, "credentials_changed");
    serverCatalogSnapshots.clear(event.sender.id);
  }
  rendererCredentialFingerprints.set(event.sender.id, nextFingerprint);
  return true;
});

ipcMain.handle("account:session:load", async (_event, value) => {
  if (!accountSession) accountSession = await readAccountSession();
  if (!accountSession) return null;
  if (accountSession.imageURL && !isSafeAccountAvatarDataURL(accountSession.imageURL)) {
    accountSession = await hydrateAccountSessionAvatar(accountSession);
    await persistAccountSession(accountSession).catch(() => undefined);
  }
  if (!accountSession.profileID || accountSession.profileID !== accountSession.accountID ||
      !accountSession.displayName ||
      accountSession.expiresAt <= Date.now() + 5 * 60_000) {
    try { return await refreshCurrentAccountSession(value?.profileID); }
    catch (error) {
      if (accountSession.expiresAt <= Date.now()) {
        await clearPersistedAccountSession();
        publishAccountSession(error);
        return null;
      }
    }
  }
  scheduleAccountSessionRefresh();
  return publicSession(accountSession);
});

ipcMain.handle("account:sign-in", async (_event, value) => {
  const baseURL = normalizeServerBaseURL(ACCOUNT_SIGN_IN_URL).origin;
  const configuration = await fetchAuthConfiguration(baseURL);
  const provider = String(value?.provider || "").trim().toLowerCase();
  const pkce = createPKCE();
  const destination = authorizationURL(configuration, provider, pkce.challenge, pkce.state);
  const pending = {
    baseURL,
    configuration,
    verifier: pkce.verifier,
    state: pkce.state,
    startedAt: Date.now(),
    migrationProfileID: String(value?.profileID || "").trim() || null,
  };
  pendingAccountSignIn = pending;
  try {
    await openAccountSignInBrowser(destination);
  } catch (error) {
    if (pendingAccountSignIn === pending) pendingAccountSignIn = null;
    throw error;
  }
  return { started: true, provider };
});

ipcMain.handle("account:session:refresh", async () => refreshCurrentAccountSession());

ipcMain.handle("account:sign-out", async () => {
  stopAllListenAlong("signed_out");
  const active = accountSession || await readAccountSession();
  if (active) {
    const configuration = await fetchAuthConfiguration(active.baseURL).catch(() => null);
    if (configuration) await revokeAuthSession(configuration, active);
  }
  pendingAccountSignIn = null;
  await clearPersistedAccountSession();
  publishAccountSession();
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
    tracks.push(await enrichedTrack(destination, {
      size: information.size,
      preservesUnlinkedImport: true,
    }));
  }
  return tracks;
});

ipcMain.handle("profile-picture:load", async (_event, { serverURL, profileID } = {}) => {
  const destination = profilePicturePath(serverURL, profileID);
  try {
    const image = nativeImage.createFromPath(destination);
    return image.isEmpty() ? null : image.toDataURL();
  } catch {
    return null;
  }
});

ipcMain.handle("profile-picture:choose", async (_event, { serverURL, profileID } = {}) => {
  const result = await dialog.showOpenDialog(mainWindow, {
    title: "Choose a profile picture",
    properties: ["openFile"],
    filters: [{ name: "Pictures", extensions: ["avif", "gif", "jpeg", "jpg", "png", "webp"] }],
  });
  if (result.canceled || result.filePaths.length !== 1) return null;
  const source = result.filePaths[0];
  const information = await fs.stat(source);
  if (!information.isFile() || information.size > MAX_PROFILE_PICTURE_SOURCE_BYTES) {
    throw new Error("Profile pictures must be smaller than 32 MB.");
  }
  const bytes = normalizedProfilePicture(nativeImage.createFromPath(source));
  const paths = await ensureDirectories();
  const destination = profilePicturePath(serverURL, profileID);
  if (path.dirname(destination) !== paths.profilePictures) throw new Error("Invalid profile-picture destination.");
  await atomicWriteFile(destination, bytes);
  return nativeImage.createFromBuffer(bytes).toDataURL();
});

ipcMain.handle("profile-picture:remove", async (_event, { serverURL, profileID } = {}) => {
  await fs.rm(profilePicturePath(serverURL, profileID), { force: true });
  return true;
});

ipcMain.handle("local-import:capabilities", () => ({
  enabled: localImportEnabled(),
  sources: ["spotify", "spotify_playlists", "soundcloud", "soundcloud_playlists", "youtube", "youtube_playlists", "youtube_music", "debrid_vault", "torbox"],
  searchProviders: ["spotify", "soundcloud", "youtube"],
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
  const soundCloudSource = isSoundCloudURL(source);
  const filePath = path.join(directory, soundCloudSource ? "preview.mp3" : "preview.m4a");
  const operation = { controller, directory };
  activeLocalImportPreviews.set(senderID, operation);
  try {
    const resolved = soundCloudSource
      ? await resolveSoundCloudAudio(source, controller.signal)
      : await resolveYouTubeAudio(source, controller.signal);
    if (resolved.contentLength > MAX_LOCAL_IMPORT_PREVIEW_BYTES) {
      throw new LocalImportError("previewing", "PREVIEW_TOO_LARGE", "This source is too large to preview. You can still select and import it.");
    }
    if (soundCloudSource) await downloadResolvedSoundCloudAudio(resolved, filePath, controller.signal);
    else await downloadResolvedAudio(resolved, filePath, controller.signal);
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
    const input = String(source || "").trim();
    const result = !looksLikeLink(input)
      ? await searchAllPlatforms(input, controller.signal, fetch, { mediaKind })
      : await resolveLocalImportSource(input, controller.signal, publish, {
      searchYouTubeAudioSources: async (track, signal) => {
        const reviewedSearch = (async () => {
          const exactAdminToken = canonicalCredentialToken(adminToken);
          if (!exactAdminToken) return [];
          const requestContext = await clientConfigContext(baseURL, profileID);
          return searchFileBackedSources(track, {
            baseURL: requestContext.base.href,
            adminToken: exactAdminToken,
            profileID,
            clientContextHeaders: { ...requestContext.expected.request_headers },
          }, signal);
        })();
        const [youtubeResult, externalResult] = await Promise.allSettled([
          searchYouTubeAudioSources(track, signal),
          reviewedSearch,
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

ipcMain.handle("server:source-metadata", async (_event, { sourceURL, mediaKind } = {}) => {
  if (!localImportEnabled()) throw new Error("Local link metadata resolution is disabled in this build.");
  const source = preservedMediaSourceURL(sourceURL);
  if (!source) throw new Error("The server returned an invalid saved source link.");
  const normalizedMediaKind = mediaKind === "video" ? "video" : "audio";
  const signal = AbortSignal.timeout(15_000);
  const track = await resolveLocalImportMetadata(source, signal, {}, { mediaKind: normalizedMediaKind });
  return {
    title: boundedText(track?.title, 500) || null,
    artist: boundedText(track?.artist, 500) || null,
    album: boundedText(track?.album, 500) || null,
    duration: Number.isFinite(Number(track?.durationSeconds))
      ? Math.max(0, Number(track.durationSeconds))
      : null,
    artworkURL: safeArtworkURL(track?.artworkURL)?.href || null,
    mediaKind: normalizedMediaKind,
  };
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
    const base = normalizeBaseURL(value.baseURL);
    const adminToken = canonicalCredentialToken(value.adminToken);
    await requireClientUploadMode({
      baseURL: base.href,
      token: adminToken,
      profileID: value.profileID,
      mode: "external_object",
      force: true,
    });
    const paths = await ensureDirectories();
    const pending = pendingExternalImports.get(event.sender.id) || null;
    const fileID = Number(value.fileID);
    if (value.resumeSelection && (!pending || !Number.isSafeInteger(fileID))) {
      throw new LocalImportError("awaiting_selection", "EXTERNAL_SELECTION_EXPIRED", "Choose the file-backed release again before selecting its audio file.");
    }
    const result = await importFileBackedSource({
      baseURL: base.href,
      adminToken,
      profileID: value.profileID,
      sourceURL: value.sourceURL,
      sourceIdentity: value.sourceIdentity,
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
      return { ok: true, result: { kind: "duplicate", trackID: result.track.id, sourceIdentity: result.sourceIdentity || null, serverBacked: true, remoteSong: result.remoteSong } };
    }
    const track = await enrichedTrack(result.filePath, {
      title: result.metadata.title,
      artist: result.metadata.artist,
      album: result.metadata.album,
      artwork: result.artwork || null,
      artworkURL: result.metadata.artworkURL,
      size: result.size,
      sourceURL: result.sourceURL,
      sourceIdentity: result.sourceIdentity || value.sourceIdentity,
      sourceSha256: result.sourceSha256,
      contentSha256: result.contentSha256,
      preservesUnlinkedImport: true,
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
      sourceIdentity: value.sourceIdentity,
      mediaKind: value.mediaKind,
      metadata: value.metadata,
      existing: Array.isArray(value.existing) ? value.existing : [],
      destinationDirectory: paths.local,
      temporaryRoot: app.getPath("temp"),
    }, controller.signal, publish);
    if (result.kind === "duplicate") {
      publish({ stage: "local_complete", duplicate: true, trackID: result.track.id });
      return { ok: true, result: { kind: "duplicate", trackID: result.track.id, sourceIdentity: result.sourceIdentity || null } };
    }
    const track = await enrichedTrack(result.filePath, {
      title: result.metadata.title,
      artist: result.metadata.artist,
      album: result.metadata.album,
      artwork: result.artwork || null,
      artworkURL: result.metadata.artworkURL,
      size: result.size,
      sourceURL: result.sourceURL,
      sourceIdentity: result.sourceIdentity || value.sourceIdentity,
      sourceSha256: result.sourceSha256,
      contentSha256: result.contentSha256,
      preservesUnlinkedImport: true,
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

ipcMain.handle("local-import:upload", async (event, {
  baseURL, adminToken, profileID, filePath, title, artist, album, duration, artworkURL, mediaSourceURL, mediaKind, mode,
} = {}) => {
  if (!localImportEnabled()) {
    return { ok: false, error: { stage: "syncing", code: "FEATURE_DISABLED", message: "Local link import is disabled in this build." } };
  }
  const controller = beginLocalImport(event);
  try {
    adminToken = canonicalCredentialToken(adminToken);
    const paths = await ensureDirectories();
    const absolute = path.resolve(String(filePath || ""));
    const managedRoots = [paths.local, paths.remote];
    if (!isManagedLibraryFile(absolute, managedRoots)) {
      throw new LocalImportError("syncing", "INVALID_LOCAL_FILE", "Only a song already saved in the managed Resonance library can be uploaded.");
    }
    const information = await fs.stat(absolute);
    if (!information.isFile() || information.size <= 0) {
      throw new LocalImportError("syncing", "INVALID_LOCAL_FILE", "The local song file is missing or empty.");
    }
    if (!adminToken) {
      throw new LocalImportError("syncing", "ADMIN_KEY_REQUIRED", "Sign in to your Resonance account before uploading this local song.");
    }
    const base = normalizeBaseURL(baseURL);
    const requestedMode = ["server_source_link", "reviewed_match"].includes(mode) ? mode : "local_file";
    const requestContext = await clientConfigContext(base.href, profileID);
    const filename = serverUploadFilename(absolute, title);
    const url = new URL("api/v1/admin/songs", base);
    let completed = 0;
    const publishUploadProgress = () => {
      if (!event.sender.isDestroyed()) {
        event.sender.send("local-import:progress", {
          stage: "syncing",
          profileID: String(profileID || "default"),
          currentFile: filename,
          completed,
          total: 1,
        });
      }
    };
    publishUploadProgress();
    await requireClientUploadMode({
      baseURL: base.href,
      token: adminToken,
      profileID,
      mode: requestedMode,
      force: true,
    });
    controller.signal.throwIfAborted();
    const response = await putSourceLinkRegistration({
      base,
      url,
      headers: {
        ...profileHeaders(adminToken, profileID),
        ...requestContext.expected.request_headers,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      item: { mediaSourceURL, mediaKind },
      signal: controller.signal,
    });
    if (response.status === 201 || response.status === 409) {
      invalidateServerCatalogSnapshots(base, profileID);
    }
    const { song: remoteSong } = await readServerUploadResponse(response, { serverOrigin: base.origin });
    completed = 1;
    publishUploadProgress();
    event.sender.send("local-import:progress", {
      stage: "complete",
      profileID: String(profileID || "default"),
      currentFile: filename,
      completed,
      total: 1,
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
  const exactToken = canonicalCredentialToken(token);
  if (!exactToken) throw new Error("Enter the required server credential.");
  return { Authorization: `Bearer ${exactToken}` };
}

function profileHeaders(token, profileID) {
  return {
    ...authorizationHeaders(token),
    "X-Resonance-Profile": String(profileID || "default"),
  };
}

async function boundedResponseBody(response, maximumBytes, label) {
  const declaredLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > maximumBytes) {
    throw new Error(`${label} is too large.`);
  }
  const reader = response.body?.getReader();
  if (!reader) return Buffer.alloc(0);
  const chunks = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maximumBytes) {
      await reader.cancel();
      throw new Error(`${label} is too large.`);
    }
    chunks.push(Buffer.from(value));
  }
  return Buffer.concat(chunks, total);
}

async function clientConfigContext(baseURL, profileID) {
  const base = normalizeBaseURL(baseURL);
  const stored = await ensureClientConfigStateLoaded();
  const expected = clientConfigRequestContext({
    origin: base.origin,
    profileID: String(profileID || "default"),
    appVersion: app.getVersion(),
    appBuild: WINDOWS_APP_BUILD,
    cohortKey: stored.cohort_key,
  });
  return { base, stored, expected };
}

async function loadClientConfig({ baseURL, token, profileID, force = false }) {
  const exactToken = canonicalCredentialToken(token);
  if (!exactToken) return { config: safeClientConfig(), source: "safe-defaults" };
  let context;
  try {
    context = await clientConfigContext(baseURL, profileID);
  } catch {
    return { config: safeClientConfig(), source: "safe-defaults" };
  }
  const cacheKey = configCacheKey(context.expected, exactToken);
  const cachedForCurrentState = () => currentFloorSafeCachedConfig(
    context.stored,
    cacheKey,
    (record) => validCachedClientConfig(record, {
      expected: context.expected,
      token: exactToken,
    }),
  );
  const cached = cachedForCurrentState();
  if (!force && cached) return { config: cached, source: "cache" };
  const safeResult = () => ({ config: safeClientConfig(context.expected), source: "safe-defaults" });
  const cachedResult = () => {
    const currentCached = cachedForCurrentState();
    return currentCached ? { config: currentCached, source: "cache" } : safeResult();
  };
  const evictCache = async () => {
    await mutateClientConfigState(async () => {
      if (!context.stored.entries[cacheKey]) return;
      delete context.stored.entries[cacheKey];
      try {
        await persistClientConfigState();
      } catch {
        // Keep the record unavailable for this process. The durable revision
        // floor still prevents a lower signed snapshot from being activated.
      }
    });
  };

  let response = null;
  try {
    response = await fetchSameOrigin(context.base, new URL("api/v1/client-config", context.base), {
      headers: {
        ...profileHeaders(exactToken, profileID),
        ...context.expected.request_headers,
        Accept: "application/json",
      },
      redirect: "manual",
      signal: AbortSignal.timeout(10_000),
    });
  } catch {
    return cachedResult();
  }
  try {
    if (response.status === 404 || response.status === 405) {
      await evictCache();
      return { config: safeClientConfig(context.expected), source: "legacy" };
    }
    if (response.status >= 500) return cachedResult();
    if (response.status !== 200) {
      await evictCache();
      return safeResult();
    }
    const contentType = String(response.headers.get("content-type") || "").toLocaleLowerCase();
    if (!contentType.startsWith("application/json")) {
      await evictCache();
      return safeResult();
    }
    let rawBody;
    try {
      rawBody = await boundedResponseBody(response, CLIENT_CONFIG_MAX_BYTES, "Server client configuration");
    } catch (error) {
      if (/too large/i.test(String(error?.message || ""))) await evictCache();
      return /too large/i.test(String(error?.message || "")) ? safeResult() : cachedResult();
    }
    const contentDigest = response.headers.get("content-digest");
    const signature = response.headers.get("x-resonance-config-signature");
    const etag = response.headers.get("etag") || undefined;
    let verified;
    try {
      verified = verifyClientConfigResponse({
        rawBody,
        contentDigest,
        signature,
        token: exactToken,
        expected: context.expected,
        etag,
      });
    } catch {
      await evictCache();
      return safeResult();
    }
    try {
      await mutateClientConfigState(async () => {
        const highestRevision = monotonicClientConfigRevision(
          verified,
          clientConfigRevisionFloor(context.stored, cacheKey),
        );
        const record = createClientConfigCacheRecord({
          rawBody,
          contentDigest,
          signature,
          token: exactToken,
          expected: context.expected,
          etag,
          highestRevision,
        });
        await commitClientConfigRecord({
          state: context.stored,
          cacheKey,
          record,
          revision: highestRevision,
          persist: persistClientConfigState,
          maximumEntries: 64,
        });
      });
    } catch {
      return cachedResult();
    }
    return { config: { ...verified, source: "remote" }, source: "remote" };
  } finally {
    response?.body?.cancel?.().catch?.(() => undefined);
  }
}

async function requireClientUploadMode({ baseURL, token, profileID, mode, force = false }) {
  const evaluated = await loadClientConfig({ baseURL, token, profileID, force });
  const values = evaluated.config?.values || {};
  const kills = evaluated.config?.kill_switches || {};
  const enabled = !kills.all_uploads
    && (mode === "local_file"
      ? values["upload.local_file"] === true
      : mode === "server_source_link"
        ? !kills.link_imports && values["upload.server_source_link"] === true
        : mode === "reviewed_match"
          && values["upload.reviewed_match"] === true
          && values["upload.local_file"] === true
          && values["matcher.mode"] === "review");
  if (!enabled) {
    const error = new Error(`The signed server configuration disables ${mode.replaceAll("_", " ")} uploads.`);
    error.name = "ClientUploadPolicyError";
    error.retryable = false;
    error.verifiedRevocation = evaluated.config?.verified === true;
    throw error;
  }
  return evaluated.config;
}

async function requireOfflineDownloadMode({ baseURL, token, profileID, force = true }) {
  const evaluated = await loadClientConfig({ baseURL, token, profileID, force });
  const values = evaluated.config?.values || {};
  const kills = evaluated.config?.kill_switches || {};
  if (kills.offline_downloads || values["download.offline_mode"] !== "verified_file_cache") {
    const error = new Error("Offline downloads are disabled by the signed server configuration.");
    error.verifiedRevocation = true;
    throw error;
  }
  return evaluated.config;
}

class OfflineDownloadPolicyError extends Error {
  constructor(message = "Offline download authorization expired or was revoked.") {
    super(message);
    this.name = "OfflineDownloadPolicyError";
    this.retryable = false;
  }
}

async function beginOfflineDownloadPolicyLease({ baseURL, token, profileID, parentSignal }) {
  let initialConfig;
  try {
    initialConfig = await requireOfflineDownloadMode({ baseURL, token, profileID, force: false });
  } catch (error) {
    const policyError = new OfflineDownloadPolicyError(error?.message || undefined);
    policyError.verifiedRevocation = error?.verifiedRevocation === true;
    throw policyError;
  }
  parentSignal?.throwIfAborted();
  return createRenewablePolicyLease({
    initialConfig,
    allowUnsignedInitial: initialConfig?.verified !== true,
    parentSignal,
    renew: () => requireOfflineDownloadMode({ baseURL, token, profileID, force: true }),
    errorFactory: (message) => new OfflineDownloadPolicyError(message),
  });
}

async function requireServerStreamMode({ baseURL, token, profileID, force = false }) {
  const evaluated = await loadClientConfig({ baseURL, token, profileID, force });
  const values = evaluated.config?.values || {};
  const kills = evaluated.config?.kill_switches || {};
  const streamOnly = values["download.offline_mode"] === "stream_only" || kills.offline_downloads === true;
  if (evaluated.config?.verified !== true
      || !streamOnly
      || values["download.playback_mode"] !== "same_origin_resolver") {
    const error = new ServerStreamValidationError(
      "STREAM_POLICY_DISABLED",
      "The signed server configuration does not authorize stream-only playback.",
      403,
    );
    // Safe/legacy/invalid fallbacks do not authorize StreamOnly. Only a
    // still-fresh verified cached allow-policy reaches this branch-free path.
    error.verifiedRevocation = true;
    throw error;
  }
  return evaluated.config;
}

ipcMain.handle("server:client-config", async (_event, settings = {}) => loadClientConfig(settings));

function exactYouTubeSourcePageURL(value) {
  const source = typeof value === "string" ? value.trim() : "";
  return /^https:\/\/www\.youtube\.com\/watch\?v=[A-Za-z0-9_-]{11}$/.test(source) ? source : null;
}

function sanitizedSourceImportSong(value, serverOrigin) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const id = boundedText(value.id, 128);
  if (!id) return null;
  const sameOriginURL = (candidate) => {
    if (typeof candidate !== "string" || !candidate.trim()) return null;
    try {
      const url = new URL(String(candidate || ""), `${serverOrigin}/`);
      return url.origin === serverOrigin && !url.username && !url.password && !url.hash ? url.href : null;
    } catch {
      return null;
    }
  };
  return {
    id,
    filename: boundedText(value.filename || value.name, 500),
    name: boundedText(value.name || value.filename, 500),
    title: boundedText(value.title, 500) || boundedText(value.name || value.filename, 500) || "Untitled song",
    artist: boundedText(value.artist, 500),
    album: boundedText(value.album, 500),
    size: Number.isSafeInteger(value.size) && value.size >= 0 ? value.size : 0,
    duration_seconds: Number.isFinite(Number(value.duration_seconds)) && Number(value.duration_seconds) >= 0
      ? Number(value.duration_seconds)
      : null,
    content_sha256: /^[a-f0-9]{64}$/i.test(String(value.content_sha256 || ""))
      ? String(value.content_sha256).toLocaleLowerCase()
      : null,
    content_type: boundedText(value.content_type, 128),
    download_url: sameOriginURL(value.download_url),
    stream_url: sameOriginURL(value.stream_url),
    artwork_url: sameOriginURL(value.artwork_url),
  };
}

ipcMain.handle("server:source-import", async (event, settings = {}) => {
  const controller = beginLocalImport(event);
  try {
  const base = normalizeBaseURL(settings.baseURL);
  const adminToken = canonicalCredentialToken(settings.adminToken);
  const configToken = canonicalCredentialToken(settings.token || adminToken);
  const profileID = String(settings.profileID || "default");
  if (!adminToken) throw new Error("Sign in to your Resonance account before importing a source link.");
  if (!configToken) throw new Error("A server credential is required before importing a source link.");
  if (settings.mode !== "server_source_link") {
    throw new Error("The source-import endpoint is available only for server source-link mode.");
  }
  const sourcePageURL = exactYouTubeSourcePageURL(settings.sourcePageURL);
  if (!sourcePageURL) {
    throw new Error("Source import requires the original canonical HTTPS YouTube song page.");
  }
  const requestContext = await clientConfigContext(base.href, profileID);
  const body = {
    schema_version: 1,
    source_page_url: sourcePageURL,
  };
  await requireClientUploadMode({
    baseURL: base.href,
    token: configToken,
    profileID,
    mode: "server_source_link",
    force: true,
  });
  controller.signal.throwIfAborted();
  const response = await fetchSameOrigin(base, new URL("api/v1/admin/source-imports", base), {
    method: "POST",
    headers: {
      ...profileHeaders(adminToken, profileID),
      ...requestContext.expected.request_headers,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify(body),
    redirect: "manual",
    signal: AbortSignal.any([controller.signal, AbortSignal.timeout(5 * 60 * 1000)]),
  });
  // HTTP 201/409 means the server has committed. Stop exposing cancellation
  // before reading and reconciling that authoritative response body. Error
  // responses remain cancellable while their body is read.
  if (response.status === 201 || response.status === 409) {
    invalidateServerCatalogSnapshots(base, profileID);
    finishLocalImport(event, controller);
  }
  const responseContentType = String(response.headers.get("content-type") || "")
    .split(";", 1)[0]
    .trim()
    .toLowerCase();
  if (responseContentType !== "application/json") {
    response.body?.cancel?.().catch?.(() => undefined);
    throw new Error(`Server returned HTTP ${response.status} with an invalid source-import content type.`);
  }
  const rawBody = await boundedResponseBody(response, CLIENT_CONFIG_MAX_BYTES, "Source-import response");
  let payload = null;
  try { payload = JSON.parse(rawBody.toString("utf8")); }
  catch { /* The status-specific error below is clearer than a JSON parse failure. */ }
  if (response.status !== 201 && response.status !== 409) {
    const detail = boundedText(payload?.error, 500);
    throw new Error(`Server returned HTTP ${response.status}${detail ? `: ${detail}` : ""}`);
  }
  if (payload?.schema_version !== 1) {
    throw new Error("The server returned an unsupported source-import response.");
  }
  if (response.status === 409) {
    if (payload.status !== "duplicate") throw new Error("The server returned an unsupported source-import response.");
    const song = sanitizedSourceImportSong(payload.duplicate_of, base.origin);
    if (!song) throw new Error("The server returned an invalid duplicate source-import song record.");
    return { schema_version: 1, status: "duplicate", song };
  }
  if (!["imported", "restored"].includes(payload.status)) {
    throw new Error("The server returned an unsupported source-import response.");
  }
  const song = sanitizedSourceImportSong(payload.song, base.origin);
  if (!song) throw new Error("The server returned an invalid source-import song record.");
  return { schema_version: 1, status: payload.status, song };
  } finally {
    finishLocalImport(event, controller);
  }
});

ipcMain.handle("server:profiles:get", async (_event, { baseURL, token }) => {
  if (!token) throw new Error("Sign in to your Resonance account.");
  const base = normalizeBaseURL(baseURL);
  const response = await fetchSameOrigin(base, new URL("api/v1/profiles", base), { headers: authorizationHeaders(token) });
  if (!response.ok) throw await serverResponseError(response);
  return readResponseJSON(response, MAX_SERVER_JSON_RESPONSE_BYTES, "Server profiles response");
});

ipcMain.handle("server:profiles:create", async (_event, { baseURL, token, name }) => {
  if (!token) throw new Error("Sign in to your Resonance account.");
  const base = normalizeBaseURL(baseURL);
  const response = await fetchSameOrigin(base, new URL("api/v1/profiles", base), {
    method: "POST",
    headers: { ...profileHeaders(token, "default"), "Content-Type": "application/json" },
    body: JSON.stringify({ name }),
  });
  if (!response.ok) throw await serverResponseError(response);
  return readResponseJSON(response, MAX_SERVER_JSON_RESPONSE_BYTES, "Server profile response");
});

ipcMain.handle("server:artwork", async (_event, { baseURL, token, profileID, songID }) => {
  if (!token) throw new Error("Sign in to your Resonance account.");
  if (!songID) throw new Error("Song artwork is unavailable.");
  const base = normalizeBaseURL(baseURL);
  const artworkURL = new URL(`api/v1/songs/${encodeURIComponent(songID)}/artwork`, base);
  const response = await fetchSameOrigin(base, artworkURL, { headers: profileHeaders(token, profileID) });
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

async function fetchServerCatalogDocument(base, token, profileID, { signal, extraHeaders = {} } = {}) {
  const response = await fetchSameOrigin(base, new URL("api/v1/songs", base), {
    headers: { ...profileHeaders(token, profileID), ...extraHeaders, Accept: "application/json" },
    redirect: "manual",
    signal,
  });
  if (response.status !== 200) {
    response.body?.cancel?.().catch?.(() => undefined);
    throw new Error(`Server catalog request returned HTTP ${response.status}.`);
  }
  const contentType = String(response.headers.get("content-type") || "").split(";", 1)[0].trim().toLowerCase();
  if (contentType !== "application/json") {
    response.body?.cancel?.().catch?.(() => undefined);
    throw new Error("The server returned an invalid catalog content type.");
  }
  const rawBody = await boundedResponseBody(response, MAX_SERVER_STREAM_CATALOG_BYTES, "Server catalog");
  let catalog;
  try { catalog = JSON.parse(rawBody.toString("utf8")); }
  catch { throw new Error("The server returned malformed catalog JSON."); }
  if (!catalog || typeof catalog !== "object" || Array.isArray(catalog) || !Array.isArray(catalog.songs)) {
    throw new Error("The server returned an invalid catalog document.");
  }
  return catalog;
}

function rememberServerCatalogSnapshot(ownerID, base, token, profileID, catalog) {
  return serverCatalogSnapshots.remember(ownerID, {
    origin: base.origin,
    profileID: String(profileID || "default"),
    credentialFingerprint: serverCatalogCredentialFingerprint(token),
  }, catalog);
}

function serverCatalogSnapshot(ownerID, base, token, profileID) {
  return serverCatalogSnapshots.read(ownerID, {
    origin: base.origin,
    profileID: String(profileID || "default"),
    credentialFingerprint: serverCatalogCredentialFingerprint(token),
  });
}

function invalidateServerCatalogSnapshots(base, profileID) {
  return serverCatalogSnapshots.clearContext({
    origin: base.origin,
    profileID: String(profileID || "default"),
  });
}

ipcMain.handle("server:catalog", async (event, { baseURL, token, profileID }) => {
  if (!token) throw new Error("Sign in to your Resonance account.");
  const base = normalizeBaseURL(baseURL);
  const catalog = await fetchServerCatalogDocument(base, token, profileID);
  return rememberServerCatalogSnapshot(event.sender.id, base, token, profileID, catalog);
});

ipcMain.handle("server:playlists:get", async (_event, { baseURL, token, profileID }) => {
  if (!token) throw new Error("Sign in to your Resonance account.");
  const base = normalizeBaseURL(baseURL);
  const response = await fetchSameOrigin(base, new URL("api/v1/playlists", base), { headers: profileHeaders(token, profileID) });
  if (!response.ok) throw await serverResponseError(response);
  return readResponseJSON(response, MAX_SERVER_JSON_RESPONSE_BYTES, "Server playlists response");
});

ipcMain.handle("server:playlists:put", async (_event, { baseURL, token, profileID, document }) => {
  if (!token) throw new Error("Sign in to your Resonance account.");
  const base = normalizeBaseURL(baseURL);
  const response = await fetchSameOrigin(base, new URL("api/v1/playlists", base), {
    method: "PUT",
    headers: {
      ...profileHeaders(token, profileID),
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify(document),
  });
  if (response.status !== 200 && response.status !== 409) throw await serverResponseError(response);
  return {
    status: response.status,
    document: await readResponseJSON(response, MAX_SERVER_JSON_RESPONSE_BYTES, "Server playlist response"),
  };
});

ipcMain.handle("server:listening-history:post", async (_event, { baseURL, token, profileID, entries }) => {
  if (!token) throw new Error("Sign in to your Resonance account.");
  const minimalEntries = normalizeListeningHistoryUploadEntries(entries);
  const base = normalizeBaseURL(baseURL);
  const response = await fetchSameOrigin(base, new URL("api/v1/listening-history", base), {
    method: "POST",
    headers: {
      ...profileHeaders(token, profileID),
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({ entries: minimalEntries, client: "windows" }),
  });
  if (response.status === 404 || response.status === 405) return { supported: false, accepted: 0 };
  if (!response.ok) throw await serverResponseError(response);
  return {
    supported: true,
    ...(await readResponseJSON(response, MAX_SERVER_JSON_RESPONSE_BYTES, "Listening-history response")),
  };
});

ipcMain.handle("server:listening-history:get", async (_event, { baseURL, token, profileID, limit = 2000 }) => {
  if (!token) throw new Error("Sign in to your Resonance account.");
  const base = normalizeBaseURL(baseURL);
  const url = new URL("api/v1/listening-history", base);
  url.searchParams.set("limit", String(Math.max(1, Math.min(2000, Math.floor(Number(limit) || 2000)))));
  const response = await fetchSameOrigin(base, url, {
    headers: {
      ...profileHeaders(token, profileID),
      Accept: "application/json",
    },
  });
  if (response.status === 404 || response.status === 405) {
    return { supported: false, profile_id: profileID || "default", entries: [] };
  }
  if (!response.ok) throw await serverResponseError(response);
  return {
    supported: true,
    ...(await readResponseJSON(response, MAX_SERVER_JSON_RESPONSE_BYTES, "Listening-history response")),
  };
});

function sameOriginServerMediaURL(candidate, base, label) {
  if (!candidate) throw new Error(`The server did not provide a ${label} URL.`);
  const url = new URL(String(candidate), base);
  if (url.origin !== base.origin || url.username || url.password || url.hash) {
    throw new Error(`The server returned an unsafe cross-origin ${label} URL.`);
  }
  return url;
}

function validateCatalogMediaLocation(song) {
  const location = song?.media_location;
  if (!location || typeof location !== "object" || Array.isArray(location)) return null;
  const declaredSize = Number(location.byte_length);
  if (Number.isSafeInteger(declaredSize) && declaredSize >= 0 && declaredSize !== Number(song.size)) {
    throw new Error(`The media descriptor size does not match the catalog for ${song.title || song.name || song.id}.`);
  }
  const descriptorSHA256 = catalogSHA256({ content_sha256: location.content_sha256 });
  const songSHA256 = catalogSHA256(song);
  if (descriptorSHA256 && songSHA256 && descriptorSHA256 !== songSHA256) {
    throw new Error(`The media descriptor checksum does not match the catalog for ${song.title || song.name || song.id}.`);
  }
  return location;
}

async function refreshedSongMediaLocation(song, base, token, profileID, requestContext, signal) {
  const location = validateCatalogMediaLocation(song);
  const refreshURL = sameOriginServerMediaURL(
    location?.refresh_url || `/api/v1/songs/${encodeURIComponent(song.id)}/media-location/refresh`,
    base,
    "media refresh",
  );
  const response = await fetchSameOrigin(base, refreshURL, {
    method: "POST",
    headers: {
      ...profileHeaders(token, profileID),
      ...requestContext.expected.request_headers,
      Accept: "application/json",
    },
    redirect: "manual",
    signal,
  });
  if (response.status !== 200) throw new Error(`Media refresh failed for ${song.title || song.name || song.id} (HTTP ${response.status}).`);
  const rawBody = await boundedResponseBody(response, CLIENT_CONFIG_MAX_BYTES, "Media refresh response");
  let payload;
  try { payload = JSON.parse(rawBody.toString("utf8")); }
  catch { throw new Error("The server returned an invalid media refresh response."); }
  const refreshed = payload?.media_location;
  if (!refreshed || typeof refreshed !== "object" || Array.isArray(refreshed)) {
    throw new Error("The server returned an invalid media refresh descriptor.");
  }
  validateCatalogMediaLocation({ ...song, media_location: refreshed });
  return refreshed;
}

async function refreshedSongDownloadURL(song, base, token, profileID, requestContext, signal) {
  const refreshed = await refreshedSongMediaLocation(song, base, token, profileID, requestContext, signal);
  return sameOriginServerMediaURL(refreshed.download_url, base, "download");
}

function revokeServerStreamSession(sessionID) {
  const session = serverStreamSessions.get(sessionID);
  if (!session) return false;
  serverStreamSessions.delete(sessionID);
  if (session.expirationTimer) clearTimeout(session.expirationTimer);
  for (const controller of session.controllers) controller.abort();
  session.controllers.clear();
  return true;
}

function revokeServerStreamsForOwner(ownerWebContentsID) {
  for (const [sessionID, session] of serverStreamSessions) {
    if (session.ownerWebContentsID === ownerWebContentsID) revokeServerStreamSession(sessionID);
  }
}

function revokeAllServerStreams() {
  for (const sessionID of [...serverStreamSessions.keys()]) revokeServerStreamSession(sessionID);
}

function activeServerStreamRequestCount() {
  let count = 0;
  for (const session of serverStreamSessions.values()) count += session.controllers.size;
  return count;
}

function pruneServerStreamSessions(now = Date.now()) {
  for (const [sessionID, session] of serverStreamSessions) {
    if (!Number.isFinite(session.createdAt)
        || now - session.createdAt >= SERVER_STREAM_SESSION_TTL_MS) {
      revokeServerStreamSession(sessionID);
    }
  }
}

function makeServerStreamCapacity() {
  pruneServerStreamSessions();
  while (serverStreamSessions.size >= MAX_SERVER_STREAM_SESSIONS) {
    const oldest = [...serverStreamSessions.entries()]
      .sort((left, right) => left[1].lastAccessAt - right[1].lastAccessAt)[0];
    if (!oldest) break;
    revokeServerStreamSession(oldest[0]);
  }
}

function makeServerStreamOwnerCapacity(ownerWebContentsID) {
  const owned = [...serverStreamSessions.entries()]
    .filter(([, session]) => session.ownerWebContentsID === ownerWebContentsID)
    .sort((left, right) => left[1].createdAt - right[1].createdAt);
  while (owned.length >= MAX_SERVER_STREAM_SESSIONS_PER_OWNER) {
    const oldest = owned.shift();
    if (oldest) revokeServerStreamSession(oldest[0]);
  }
}

function canonicalStreamSongID(value) {
  const songID = typeof value === "string" ? value.trim() : "";
  if (!songID || songID.length > 128 || songID !== value || /[\u0000-\u001f\u007f]/.test(songID)) {
    throw new ServerStreamValidationError("INVALID_SONG_ID", "A valid catalog song is required.", 400);
  }
  return songID;
}

function canonicalStreamCredential(value) {
  let token;
  try { token = canonicalCredentialToken(value); }
  catch { token = ""; }
  if (!token) {
    throw new ServerStreamValidationError("INVALID_CREDENTIAL", "A signed-in Resonance account is required.", 400);
  }
  return token;
}

function canonicalStreamProfileID(value) {
  const profileID = typeof value === "string" ? value : "default";
  if (!profileID || profileID.length > 128 || /[\u0000-\u001f\u007f]/.test(profileID)) {
    throw new ServerStreamValidationError("INVALID_PROFILE", "A valid server profile is required.", 400);
  }
  return profileID;
}

function canonicalStreamBaseURL(value) {
  const input = typeof value === "string" ? value.trim() : "";
  if (!input || input.length > 2048) {
    throw new ServerStreamValidationError("INVALID_SERVER", "A valid server URL is required.", 400);
  }
  return normalizeBaseURL(input);
}

function boundedStreamURLValue(value) {
  if (typeof value !== "string" || !value || value !== value.trim() || value.length > 4096) return null;
  return value;
}

function streamMediaURLForSong(song, base) {
  const mediaLocation = validateCatalogMediaLocation(song);
  return sameOriginServerMediaURL(mediaLocation?.stream_url || song.stream_url, base, "stream");
}

function boundedStreamCatalogSong(song) {
  const mediaLocation = validateCatalogMediaLocation(song);
  const expectedSize = supportedMediaSize(mediaLocation?.byte_length ?? song.size);
  const contentSHA256 = catalogSHA256(song);
  return Object.freeze({
    id: canonicalStreamSongID(song.id),
    filename: boundedText(song.filename || song.name, 500),
    title: boundedText(song.title || song.name, 500),
    name: boundedText(song.name || song.filename, 500),
    content_type: boundedText(song.content_type, 128),
    size: expectedSize,
    ...(contentSHA256 ? { content_sha256: contentSHA256 } : {}),
    stream_url: boundedStreamURLValue(song.stream_url),
    media_location: mediaLocation ? Object.freeze({
      byte_length: expectedSize,
      ...(catalogSHA256({ content_sha256: mediaLocation.content_sha256 })
        ? { content_sha256: catalogSHA256({ content_sha256: mediaLocation.content_sha256 }) }
        : {}),
      refresh_url: boundedStreamURLValue(mediaLocation.refresh_url),
      stream_url: boundedStreamURLValue(mediaLocation.stream_url),
    }) : null,
  });
}

async function fetchFreshStreamCatalogSong({ base, token, profileID, songID, requestContext, signal }) {
  const response = await fetchSameOrigin(base, new URL("api/v1/songs", base), {
    headers: {
      ...profileHeaders(token, profileID),
      ...requestContext.expected.request_headers,
      Accept: "application/json",
    },
    redirect: "manual",
    signal,
  });
  if (response.status !== 200) {
    response.body?.cancel?.().catch?.(() => undefined);
    throw new ServerStreamValidationError("CATALOG_UNAVAILABLE", "The server catalog is unavailable.", 502);
  }
  const contentType = String(response.headers.get("content-type") || "").split(";", 1)[0].trim().toLocaleLowerCase();
  if (contentType !== "application/json") {
    response.body?.cancel?.().catch?.(() => undefined);
    throw new ServerStreamValidationError("INVALID_CATALOG", "The server returned an invalid catalog.", 502);
  }
  const rawBody = await boundedResponseBody(response, MAX_SERVER_STREAM_CATALOG_BYTES, "Server catalog");
  let catalog;
  try { catalog = JSON.parse(rawBody.toString("utf8")); }
  catch { throw new ServerStreamValidationError("INVALID_CATALOG", "The server returned an invalid catalog.", 502); }
  const matchingSongs = Array.isArray(catalog?.songs)
    ? catalog.songs.filter((candidate) => candidate && typeof candidate === "object" && candidate.id === songID)
    : [];
  if (matchingSongs.length === 0) {
    throw new ServerStreamValidationError("SONG_NOT_FOUND", "The catalog song is unavailable.", 404);
  }
  if (matchingSongs.length !== 1) {
    throw new ServerStreamValidationError("INVALID_CATALOG", "The server returned an ambiguous catalog song.", 502);
  }
  return boundedStreamCatalogSong(matchingSongs[0]);
}

function serverStreamErrorResponse(error, expectedSize = null) {
  const status = error instanceof ServerStreamValidationError
    ? error.status
    : error?.name === "AbortError"
      ? 499
      : 502;
  const safeStatus = [400, 403, 404, 405, 416, 429, 499, 502].includes(status) ? status : 502;
  const headers = new Headers({
    "Cache-Control": "no-store, private",
    "Content-Type": "text/plain; charset=utf-8",
  });
  if (safeStatus === 405) headers.set("Allow", "GET, HEAD");
  if (safeStatus === 416 && Number.isSafeInteger(expectedSize)) {
    headers.set("Content-Range", `bytes */${expectedSize}`);
  }
  return new Response(null, { status: safeStatus, headers });
}

async function handleServerStreamRequest(request) {
  const sessionID = streamSessionIDFromURL(request.url);
  if (!sessionID) return serverStreamErrorResponse(new ServerStreamValidationError("INVALID_SESSION", "Invalid stream session.", 404));
  pruneServerStreamSessions();
  const session = serverStreamSessions.get(sessionID);
  if (!session) return serverStreamErrorResponse(new ServerStreamValidationError("INVALID_SESSION", "Invalid stream session.", 404));
  let requestedRange = null;
  let controller = null;
  let response = null;
  let removeRequestAbortListener = () => {};
  let removePolicyAbortListener = () => {};
  let requestTimeoutTimer = null;
  let idleTimeoutTimer = null;
  let policyLease = null;
  let requestFinished = false;
  const finishRequest = () => {
    if (requestFinished) return;
    requestFinished = true;
    if (controller) session.controllers.delete(controller);
    removeRequestAbortListener();
    if (requestTimeoutTimer) clearTimeout(requestTimeoutTimer);
    if (idleTimeoutTimer) clearTimeout(idleTimeoutTimer);
    removePolicyAbortListener();
    policyLease?.close();
  };
  const abortRequest = () => {
    controller?.abort();
    finishRequest();
  };
  const resetIdleTimeout = () => {
    if (idleTimeoutTimer) clearTimeout(idleTimeoutTimer);
    idleTimeoutTimer = setTimeout(abortRequest, SERVER_STREAM_IDLE_TIMEOUT_MS);
    idleTimeoutTimer.unref?.();
  };
  try {
    const method = String(request.method || "GET").toLocaleUpperCase();
    if (method !== "GET" && method !== "HEAD") {
      throw new ServerStreamValidationError("METHOD_NOT_ALLOWED", "Only GET and HEAD stream requests are supported.", 405);
    }
    requestedRange = parseSingleByteRange(request.headers.get("range"), session.expectedSize);
    if (session.controllers.size >= MAX_SERVER_STREAM_REQUESTS_PER_SESSION) {
      throw new ServerStreamValidationError("TOO_MANY_REQUESTS", "Too many active stream requests.", 429);
    }
    if (activeServerStreamRequestCount() >= MAX_ACTIVE_SERVER_STREAM_REQUESTS) {
      throw new ServerStreamValidationError("TOO_MANY_REQUESTS", "Too many active stream requests.", 429);
    }
    controller = new AbortController();
    session.controllers.add(controller);
    requestTimeoutTimer = setTimeout(abortRequest, SERVER_STREAM_REQUEST_TIMEOUT_MS);
    requestTimeoutTimer.unref?.();
    resetIdleTimeout();
    const abortUpstream = abortRequest;
    if (request.signal?.aborted) abortUpstream();
    else if (request.signal?.addEventListener) {
      request.signal.addEventListener("abort", abortUpstream, { once: true });
      removeRequestAbortListener = () => request.signal.removeEventListener("abort", abortUpstream);
    }
    const streamPolicy = await requireServerStreamMode({
      baseURL: session.base.href,
      token: session.token,
      profileID: session.profileID,
    });
    controller.signal.throwIfAborted();
    const requestContext = await clientConfigContext(session.base.href, session.profileID);
    controller.signal.throwIfAborted();
    policyLease = createRenewablePolicyLease({
      initialConfig: streamPolicy,
      renew: () => requireServerStreamMode({
        baseURL: session.base.href,
        token: session.token,
        profileID: session.profileID,
        force: true,
      }),
      parentSignal: controller.signal,
      errorFactory: (message) => new ServerStreamValidationError("STREAM_POLICY_DISABLED", message, 403),
    });
    const abortForPolicy = () => abortRequest();
    if (policyLease.signal.aborted) abortForPolicy();
    else {
      policyLease.signal.addEventListener("abort", abortForPolicy, { once: true });
      removePolicyAbortListener = () => policyLease?.signal.removeEventListener("abort", abortForPolicy);
    }
    policyLease.assertAuthorized();
    const upstreamHeaders = {
      ...profileHeaders(session.token, session.profileID),
      ...requestContext.expected.request_headers,
      Accept: "audio/*, application/ogg, application/octet-stream",
      "Accept-Encoding": "identity",
      ...(requestedRange ? { Range: requestedRange.header } : {}),
    };
    response = await fetchSameOrigin(session.base, session.mediaURL.href, {
      method,
      headers: upstreamHeaders,
      redirect: "manual",
      signal: policyLease.signal,
    });
    if (response.status === 409) {
      response.body?.cancel?.().catch?.(() => undefined);
      const refreshed = await refreshedSongMediaLocation(
        session.song,
        session.base,
        session.token,
        session.profileID,
        requestContext,
        policyLease.signal,
      );
      session.song = Object.freeze({ ...session.song, stream_url: null, media_location: Object.freeze({
        byte_length: session.expectedSize,
        ...(catalogSHA256({ content_sha256: refreshed.content_sha256 })
          ? { content_sha256: catalogSHA256({ content_sha256: refreshed.content_sha256 }) }
          : {}),
        refresh_url: boundedStreamURLValue(refreshed.refresh_url) || session.song.media_location?.refresh_url,
        stream_url: boundedStreamURLValue(refreshed.stream_url),
      }) });
      session.mediaURL = streamMediaURLForSong(session.song, session.base);
      response = await fetchSameOrigin(session.base, session.mediaURL.href, {
        method,
        headers: upstreamHeaders,
        redirect: "manual",
        signal: policyLease.signal,
      });
    }
    const validated = validateStreamResponse({
      status: response.status,
      headers: response.headers,
      expectedSize: session.expectedSize,
      requestedRange,
      method,
    });
    session.lastAccessAt = Date.now();
    if (method === "HEAD") {
      response.body?.cancel?.().catch?.(() => undefined);
      finishRequest();
      return new Response(null, { status: validated.status, headers: validated.headers });
    }
    if (!response.body) throw new ServerStreamValidationError("INVALID_STREAM_BODY", "The server returned no stream body.", 502);
    const body = createExactLengthRelay(response.body, validated.contentLength, finishRequest, resetIdleTimeout);
    return new Response(body, { status: validated.status, headers: validated.headers });
  } catch (error) {
    response?.body?.cancel?.().catch?.(() => undefined);
    controller?.abort();
    finishRequest();
    return serverStreamErrorResponse(error, session.expectedSize);
  }
}

ipcMain.handle("server:stream:create", async (event, settings = {}) => {
  const owner = event.sender;
  const trustedRendererURL = pathToFileURL(path.join(__dirname, "ui", "index.html")).href;
  if (owner.isDestroyed() || owner.getURL() !== trustedRendererURL) throw new Error("Stream playback is unavailable.");
  const credentialEpoch = rendererCredentialEpochs.get(owner.id) || 0;
  const token = canonicalStreamCredential(settings.token);
  const profileID = canonicalStreamProfileID(settings.profileID);
  const songID = canonicalStreamSongID(settings.songID);
  const base = canonicalStreamBaseURL(settings.baseURL);
  const ownerClosed = new AbortController();
  const abortForOwnerClose = () => ownerClosed.abort();
  owner.once("destroyed", abortForOwnerClose);
  try {
    await requireServerStreamMode({ baseURL: base.href, token, profileID, force: true });
    const requestContext = await clientConfigContext(base.href, profileID);
    const song = await fetchFreshStreamCatalogSong({
      base,
      token,
      profileID,
      songID,
      requestContext,
      signal: AbortSignal.any([AbortSignal.timeout(15_000), ownerClosed.signal]),
    });
    if (serverStreamSongIsVideo(song)) {
      throw new ServerStreamValidationError(
        "VIDEO_DOWNLOAD_REQUIRED",
        "Windows stream-only playback supports audio songs. Download this video before playing it.",
        415,
      );
    }
    if (owner.isDestroyed()
        || owner.getURL() !== trustedRendererURL
        || (rendererCredentialEpochs.get(owner.id) || 0) !== credentialEpoch) {
      throw new Error("Stream playback is unavailable.");
    }
    const mediaURL = streamMediaURLForSong(song, base);
    makeServerStreamCapacity();
    makeServerStreamOwnerCapacity(owner.id);
    const sessionID = randomBytes(32).toString("hex");
    const now = Date.now();
    const session = {
      ownerWebContentsID: owner.id,
      base,
      token,
      profileID,
      song,
      mediaURL,
      expectedSize: supportedMediaSize(song.media_location?.byte_length ?? song.size),
      createdAt: now,
      lastAccessAt: now,
      controllers: new Set(),
      expirationTimer: null,
    };
    session.expirationTimer = setTimeout(() => revokeServerStreamSession(sessionID), SERVER_STREAM_SESSION_TTL_MS);
    session.expirationTimer.unref?.();
    serverStreamSessions.set(sessionID, session);
    return Object.freeze({
      url: serverStreamURL(sessionID),
      historyTrackID: remoteStreamHistoryTrackID({
        serverOrigin: base.origin,
        profileID,
        songID,
      }),
    });
  } finally {
    owner.removeListener("destroyed", abortForOwnerClose);
  }
});

ipcMain.handle("server:stream:release", (event, value) => {
  const sessionID = streamSessionIDFromURL(value);
  const session = sessionID ? serverStreamSessions.get(sessionID) : null;
  if (!session || session.ownerWebContentsID !== event.sender.id) return false;
  return revokeServerStreamSession(sessionID);
});

async function downloadSavedSourceSong(song, options) {
  const sourceURL = preservedMediaSourceURL(song?.source_url);
  if (!sourceURL) throw new Error("The server returned an invalid saved source link.");
  const mediaKind = song?.media_kind === "video" ? "video" : "audio";
  const preparationContext = JSON.stringify({
    serverOrigin: new URL(options.serverOrigin).origin,
    profileID: String(options.profileID || "default"),
    songID: String(song?.id || ""),
  });
  const metadataController = new AbortController();
  const metadataSignal = AbortSignal.any([options.signal, metadataController.signal]);
  const metadataSnapshot = { settled: options.metadataIsResolved, metadata: null };
  const metadataEnrichment = options.metadataIsResolved
    ? Promise.resolve({ metadata: null, error: null })
    : resolveLocalImportMetadata(sourceURL, metadataSignal, {}, { mediaKind })
      .then((metadata) => ({ metadata, error: null }))
      .catch((error) => ({ metadata: null, error }));
  void metadataEnrichment.then((enrichment) => {
    metadataSnapshot.metadata = enrichment.metadata || null;
    metadataSnapshot.settled = true;
  }, () => {
    // The promise above already converts resolver failures into a value. Keep
    // this rejection handler as a final ownership guard if that ever changes.
    metadataSnapshot.settled = true;
  });
  try {
  // YouTube and SoundCloud can begin media discovery from their source URL
  // while missing display metadata is enriched independently. Spotify needs
  // the resolved title/artist to locate its audio match, so that provider is
  // the one unavoidable exception when the catalog truly has no metadata.
  let acquisitionMetadata = options.metadata;
  if (!options.metadataIsResolved && isSpotifyURL(sourceURL)) {
    const enrichment = await metadataEnrichment;
    options.signal.throwIfAborted();
    acquisitionMetadata = { ...options.metadata, ...(enrichment.metadata || {}) };
  }
  const resolution = await resolveLocalImportDownloadSource(
    sourceURL,
    acquisitionMetadata,
    options.signal,
    options.onProgress,
    { searchYouTubeAudioSources },
    { mediaKind, preparationContext },
  );
  if (resolution?.track?.type === "playlist") {
    throw new Error("A saved song link resolved to a playlist instead of one song.");
  }
  const candidate = resolution?.candidates?.[0];
  if (!candidate?.sourceURL) throw new Error("No downloadable source matched this saved song link.");
  const initialMetadata = serverDownloadImportedMetadata(
    resolution.track || candidate.importMetadata,
    options.metadata,
    options.metadataIsResolved,
    sourceURL,
  );
  const imported = await importConfirmedSource({
    sourceURL: candidate.sourceURL,
    sourceIdentity: normalizeSourceIdentity(candidate.sourceIdentity, {
      provider: resolution?.track?.provider,
      providerID: resolution?.track?.trackID,
      sourcePageURL: sourceURL,
    }),
    mediaKind,
    metadata: initialMetadata,
    metadataSnapshot,
    preparedSoundCloudAudio: candidate.preparedSoundCloudAudio,
    preparationContext,
    existing: options.existing,
    destinationDirectory: options.destinationDirectory,
    temporaryRoot: app.getPath("temp"),
  }, options.signal, options.onProgress);
  options.onProgress?.({ stage: "transfer_complete" });
  try {
    await options.finalizeAuthorization?.();
  } catch (error) {
    if (imported.kind === "created" && imported.filePath) {
      await fs.rm(imported.filePath, { force: true }).catch(() => undefined);
    }
    throw error;
  }
  const metadata = imported.metadata || serverDownloadImportedMetadata(
    metadataSnapshot.settled && metadataSnapshot.metadata
      ? metadataSnapshot.metadata
      : resolution.track || candidate.importMetadata,
    options.metadata,
    options.metadataIsResolved,
    sourceURL,
  );
  const duplicate = imported.kind === "duplicate" ? imported.track : null;
  const filePath = duplicate?.filePath || imported.filePath;
  if (!filePath) throw new Error("The resolved song did not produce a local file.");
  return enrichedTrack(filePath, {
    ...(duplicate || {}),
    title: metadata.title,
    artist: metadata.artist,
    album: metadata.album,
    duration: metadata.durationSeconds,
    artwork: imported.artwork || duplicate?.artwork || null,
    artworkURL: metadata.artworkURL || duplicate?.artworkURL || null,
    size: imported.size || duplicate?.size,
    sourceSha256: imported.sourceSha256 || duplicate?.sourceSha256,
    contentSha256: imported.contentSha256 || duplicate?.contentSha256,
    sourceURL,
    sourceIdentity: imported.sourceIdentity || duplicate?.sourceIdentity,
    remoteID: song.id,
    sourceServer: options.serverOrigin,
    syncProfileID: options.profileID,
    remoteModified: null,
    storageLocation: "server-cache",
    preservesUnlinkedImport: typeof duplicate?.preservesUnlinkedImport === "boolean"
      ? duplicate.preservesUnlinkedImport
      : storageLocationForPath(filePath) !== "server-cache",
  });
  } finally {
    metadataController.abort();
    void metadataEnrichment.then(() => undefined, () => undefined);
  }
}

ipcMain.handle("server:sync", async (event, {
  baseURL,
  token,
  profileID,
  existing = [],
  songIDs = null,
  songTitles = {},
  songMetadata = {},
}) => {
  token = canonicalCredentialToken(token);
  if (!token) throw new Error("Sign in to your Resonance account.");
  const base = normalizeBaseURL(baseURL);
  const controller = beginServerTransfer(event);
  const transferGeneration = controller.resonanceGeneration;
  let policyLease = null;
  let catalog = null;
  const downloaded = [];
  const replacedTrackIDs = [];
  const failed = [];
  try {
  policyLease = await beginOfflineDownloadPolicyLease({
    baseURL: base.href,
    token,
    profileID,
    parentSignal: controller.signal,
  });
  // The exact, active cached policy is sufficient to start. A server refresh
  // overlaps acquisition and invalidates this lease immediately on a verified
  // revocation or shorter expiry instead of gating the first media byte.
  const policyRefresh = policyLease.refresh();
  const { signal } = policyLease;
  const requestContext = await clientConfigContext(base.href, profileID);
  const downloadHeaders = {
    ...profileHeaders(token, profileID),
    ...requestContext.expected.request_headers,
  };
  catalog = serverCatalogSnapshot(event.sender.id, base, token, profileID);
  if (!catalog) {
    catalog = await fetchServerCatalogDocument(base, token, profileID, {
      signal,
      extraHeaders: requestContext.expected.request_headers,
    });
    rememberServerCatalogSnapshot(event.sender.id, base, token, profileID, catalog);
  }
  const paths = await ensureDirectories();
  const requested = Array.isArray(songIDs) ? new Set(songIDs) : null;
  const preferredTitles = new Map(Object.entries(
    songTitles && typeof songTitles === "object" && !Array.isArray(songTitles) ? songTitles : {},
  ).slice(0, 2_000).flatMap(([id, title]) => {
    const songID = String(id || "").trim();
    const displayTitle = typeof title === "string" ? title.trim().slice(0, 500) : "";
    return songID && songID.length <= 256 && displayTitle ? [[songID, displayTitle]] : [];
  }));
  const preferredMetadata = new Map(Object.entries(
    songMetadata && typeof songMetadata === "object" && !Array.isArray(songMetadata) ? songMetadata : {},
  ).slice(0, 2_000).flatMap(([id, metadata]) => {
    const songID = String(id || "").trim();
    const snapshot = metadata && typeof metadata === "object" && !Array.isArray(metadata)
      ? serverDownloadMetadataSnapshot(metadata)
      : null;
    return songID && songID.length <= 256 && snapshot
      ? [[songID, snapshot]]
      : [];
  }));
  const songs = (catalog.songs || []).filter((song) => !requested || requested.has(song.id));
  const pendingDownloads = [];
  for (const song of songs) {
    signal.throwIfAborted();
    const remoteName = song.filename || song.name || `Track-${song.id}.mp3`;
    const metadataSnapshot = preferredMetadata.get(String(song.id));
    const metadataContextMatches = serverDownloadMetadataContextMatches(song, metadataSnapshot);
    const displayMetadata = serverDownloadMetadata(song, metadataContextMatches ? {
      ...metadataSnapshot,
      title: metadataSnapshot?.title || preferredTitles.get(String(song.id)),
    } : {});
    const metadataIsResolved = serverDownloadMetadataIsResolved(
      song,
      metadataSnapshot,
    );
    const displayName = displayMetadata.title;
    const remoteModified = song.modified_at || song.modified_utc || null;
    const expectedSize = Number(song.size);
    const expectedSHA256 = catalogSHA256(song);
    const savedSourceURL = preservedMediaSourceURL(song.source_url);
    const mediaLocation = savedSourceURL ? null : validateCatalogMediaLocation(song);
    const matching = existing.find((item) =>
      item.remoteID === song.id
      && matchesServerOrigin(item.sourceServer, base.origin)
      && (item.syncProfileID || "default") === (profileID || "default"));
    let alreadyDownloaded = false;
    if (matching?.filePath) {
      try {
        const information = await fs.stat(matching.filePath);
        const correctSize = savedSourceURL
          ? information.size > 0
          : Number.isSafeInteger(expectedSize)
            && expectedSize > 0
            && expectedSize <= MAX_SERVER_MEDIA_BYTES
            && information.size === expectedSize;
        const correctRevision = !matching.remoteModified || !remoteModified || matching.remoteModified === remoteModified;
        const correctHash = savedSourceURL
          ? true
          : information.isFile() && correctSize && expectedSHA256
            ? await fileSHA256(matching.filePath) === expectedSHA256
            : false;
        alreadyDownloaded = information.isFile() && correctSize && correctRevision && correctHash;
      } catch {
        alreadyDownloaded = false;
      }
    }
    if (alreadyDownloaded) continue;
    pendingDownloads.push({
      song,
      remoteName,
      displayName,
      remoteModified,
      expectedSize,
      expectedSHA256,
      savedSourceURL,
      mediaLocation,
      matching,
      displayMetadata,
      metadataIsResolved,
    });
  }

  let completed = 0;
  for (const [pendingIndex, pending] of pendingDownloads.entries()) {
    signal.throwIfAborted();
    const {
      song,
      remoteName,
      displayName,
      remoteModified,
      expectedSize,
      expectedSHA256,
      savedSourceURL,
      mediaLocation,
      matching,
      displayMetadata,
      metadataIsResolved,
    } = pending;
    const itemIndex = pendingIndex + 1;
    const itemCount = pendingDownloads.length;
    let itemCompletedBytes = 0;
    let itemTotalBytes = Number.isSafeInteger(expectedSize) && expectedSize > 0 ? expectedSize : 0;
    let itemTransferStarted = false;
    const publishProgress = createServerDownloadProgressPublisher((progressEvent) => {
      if (!itemTransferStarted) return;
      if (!serverTransferIsActive(event, controller, transferGeneration)) return;
      event.sender.send("server:transfer-progress", progressEvent);
    });
    const progressEvent = (overrides = {}) => serverDownloadProgressEvent({
      song,
      preferredTitle: displayName,
      itemIndex,
      itemCount,
      completedBytes: itemCompletedBytes,
      totalBytes: itemTotalBytes,
      completedItems: completed,
      ...overrides,
    });
    const resetItemTransfer = () => {
      if (itemTransferStarted && serverTransferIsActive(event, controller, transferGeneration)) {
        event.sender.send("server:transfer-progress", {
          ...progressEvent({ completedBytes: 0, totalBytes: itemTotalBytes }),
          autoHide: false,
        });
      }
      itemTransferStarted = false;
      itemCompletedBytes = 0;
      itemTotalBytes = Number.isSafeInteger(expectedSize) && expectedSize > 0 ? expectedSize : 0;
      publishProgress.reset();
    };
    let itemSucceeded = false;
    try {
      if (savedSourceURL) {
        const downloadedTrack = await downloadSavedSourceSong(song, {
          signal: policyLease.signal,
          existing,
          destinationDirectory: paths.remote,
          serverOrigin: base.origin,
          profileID: profileID || "default",
          metadata: displayMetadata,
          metadataIsResolved,
          finalizeAuthorization: async () => {
            await policyRefresh;
            policyLease.assertAuthorized();
          },
          onProgress: (progress) => {
            if (progress?.stage !== "downloading") {
              if (itemTransferStarted && ["transfer_complete", "processing", "saving_local", "local_complete"].includes(progress?.stage)) {
                itemTotalBytes = itemTotalBytes || itemCompletedBytes;
                const transferEnd = progressEvent({
                  completedBytes: itemCompletedBytes,
                  totalBytes: itemTotalBytes,
                });
                transferEnd.autoHide = itemIndex >= itemCount;
                publishProgress(transferEnd, { force: true });
              }
              return;
            }
            itemCompletedBytes = Math.max(0, Number(progress.completed) || 0);
            itemTotalBytes = Math.max(0, Number(progress.total) || 0);
            if (itemCompletedBytes <= 0) return;
            itemTransferStarted = true;
            const event = progressEvent();
            event.autoHide = itemIndex >= itemCount && itemTotalBytes > 0 && itemCompletedBytes >= itemTotalBytes;
            publishProgress(event);
          },
        });
        policyLease.assertAuthorized();
        if (matching?.id || existing.some((item) => item.id === downloadedTrack.id)) {
          replacedTrackIDs.push(matching?.id || downloadedTrack.id);
        }
        downloaded.push(downloadedTrack);
        itemSucceeded = true;
        completed += 1;
        const completionEvent = progressEvent({
          completedBytes: itemTotalBytes || itemCompletedBytes,
          totalBytes: itemTotalBytes || itemCompletedBytes,
          completedItems: completed,
        });
        completionEvent.autoHide = itemIndex >= itemCount;
        publishProgress(completionEvent, { force: true });
        continue;
      }
      let fileURL = sameOriginServerMediaURL(mediaLocation?.download_url || song.download_url, base, "download");
      let refreshedMediaLocation = false;
      const destination = matching?.filePath && path.dirname(path.resolve(matching.filePath)) === path.resolve(paths.remote)
        ? matching.filePath
        : await uniqueDestination(paths.remote, remoteName);
      let downloadedSize = 0;
      let downloadedSHA256 = null;
      await retryServerDownload(async () => {
          policyLease.signal.throwIfAborted();
          let response = await fetchSameOrigin(base, fileURL, {
            headers: downloadHeaders,
            redirect: "manual",
            signal: policyLease.signal,
          });
          if (response.status === 409 && !refreshedMediaLocation) {
            response.body?.cancel?.().catch?.(() => undefined);
            fileURL = await refreshedSongDownloadURL(song, base, token, profileID, requestContext, policyLease.signal);
            refreshedMediaLocation = true;
            response = await fetchSameOrigin(base, fileURL, {
              headers: downloadHeaders,
              redirect: "manual",
              signal: policyLease.signal,
            });
          }
          if (response.status !== 200) throw new Error(`Download failed for ${song.title || song.name || song.id} (HTTP ${response.status})`);
          const temporary = `${destination}.${randomUUID()}.part`;
          try {
            const downloadedFile = await writeResponseToFile(response, temporary, {
              signal: policyLease.signal,
              expectedSize,
              expectedSHA256,
              maximumBytes: MAX_SERVER_MEDIA_BYTES,
              onProgress: (progress) => {
                itemCompletedBytes = Math.max(0, Number(progress.completed) || 0);
                itemTotalBytes = Math.max(0, Number(progress.total) || 0);
                if (itemCompletedBytes <= 0) return;
                const isFirstAttemptByte = !itemTransferStarted;
                itemTransferStarted = true;
                const event = progressEvent();
                event.autoHide = itemIndex >= itemCount && itemTotalBytes > 0 && itemCompletedBytes >= itemTotalBytes;
                publishProgress(event, { force: isFirstAttemptByte });
              },
            });
            downloadedSize = downloadedFile.size;
            downloadedSHA256 = downloadedFile.sha256;
            await policyRefresh;
            policyLease.assertAuthorized();
            await adoptDownloadedFile(temporary, destination, {
              assertAuthorized: () => policyLease.assertAuthorized(),
            });
          } catch (error) {
            await fs.rm(temporary, { force: true });
            throw error;
          }
      }, {
        signal: policyLease.signal,
        onRetry: resetItemTransfer,
      });
      if (matching?.id) replacedTrackIDs.push(matching.id);
      downloaded.push(await enrichedTrack(destination, {
        id: matching?.id,
        title: displayMetadata.title,
        artist: displayMetadata.artist,
        album: displayMetadata.album,
        artworkURL: displayMetadata.artworkURL,
        remoteID: song.id,
        sourceServer: base.origin,
        syncProfileID: profileID || "default",
        remoteModified,
        size: downloadedSize,
        contentSha256: downloadedSHA256,
        sourceIdentity: song.source_url
          ? normalizeSourceIdentity(matching?.sourceIdentity, { mediaSourceURL: song.source_url })
          : matching?.sourceIdentity,
        preservesUnlinkedImport: typeof matching?.preservesUnlinkedImport === "boolean"
          ? matching.preservesUnlinkedImport
          : false,
      }));
      itemSucceeded = true;
    } catch (error) {
      // A failed final attempt owns no terminal progress. Scrub its partial bytes
      // before retry reconciliation, the next item, or cancellation can proceed.
      resetItemTransfer();
      if (error?.name === "AbortError") throw error;
      if (error instanceof OfflineDownloadPolicyError) throw error;
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
    if (itemSucceeded) {
      const completionEvent = progressEvent({
        completedBytes: itemTotalBytes || itemCompletedBytes,
        totalBytes: itemTotalBytes || itemCompletedBytes,
        completedItems: completed,
      });
      completionEvent.autoHide = itemIndex >= itemCount;
      publishProgress(completionEvent, { force: true });
    }
  }
  return { catalog, downloaded, replacedTrackIDs, failed };
  } catch (error) {
    if (error?.name === "AbortError") return { catalog, downloaded, replacedTrackIDs, failed, cancelled: true };
    throw error;
  } finally {
    policyLease?.close();
    finishServerTransfer(event, controller);
  }
});

ipcMain.handle("server:upload", async (event, { baseURL, adminToken, profileID, files, retryIDs, associationConflictPaths } = {}) => {
  adminToken = canonicalCredentialToken(adminToken);
  if (!adminToken) throw new Error("Sign in to your Resonance account.");
  const base = normalizeBaseURL(baseURL);
  const requestedProfileID = String(profileID || "default");
  await requireClientUploadMode({ baseURL: base.href, token: String(adminToken), profileID: requestedProfileID, mode: "local_file", force: true });
  const requestContext = await clientConfigContext(base.href, requestedProfileID);
  await ensureServerUploadRetriesLoaded();
  let requestedFiles;
  if (Array.isArray(retryIDs)) {
    const uniqueRetryIDs = [...new Set(retryIDs.map((value) => String(value || "").trim()).filter(Boolean))];
    if (uniqueRetryIDs.length > MAX_SERVER_UPLOAD_BATCH_FILES) {
      throw new Error(`Retry at most ${MAX_SERVER_UPLOAD_BATCH_FILES} uploads at a time.`);
    }
    requestedFiles = uniqueRetryIDs.map((retryID) => serverUploadRetries.get(retryID)).filter((record) =>
      record?.serverOrigin === base.origin && record.profileID === requestedProfileID);
    if (!uniqueRetryIDs.length || requestedFiles.length !== uniqueRetryIDs.length) {
      throw new Error("One or more failed uploads are no longer authorized for retry. Choose those files again.");
    }
  } else if (Array.isArray(files)) {
    if (!files.length || files.length > MAX_SERVER_UPLOAD_BATCH_FILES) {
      throw new Error(`Choose between 1 and ${MAX_SERVER_UPLOAD_BATCH_FILES} songs to upload.`);
    }
    const paths = await ensureDirectories();
    const managedRoots = [paths.local, paths.remote];
    requestedFiles = files.map((item) => ({
      retryID: randomUUID(),
      trackID: String(item?.trackID || ""),
      filePath: path.resolve(String(item?.filePath || "")),
      title: String(item?.title || ""),
      artist: String(item?.artist || ""),
      album: String(item?.album || ""),
      duration: Number(item?.duration) || 0,
      artworkURL: safeArtworkURL(item?.artworkURL)?.href || null,
      mediaSourceURL: transientMediaSourceURL(item?.mediaSourceURL),
      mediaKind: item?.mediaKind === "video" ? "video" : "audio",
      uploadFilename: serverUploadFilename(item?.filePath, item?.title),
      serverOrigin: base.origin,
      profileID: requestedProfileID,
      createdAt: new Date().toISOString(),
    }));
    if (requestedFiles.some((item) => !item.trackID || !item.mediaSourceURL || !isManagedLibraryFile(item.filePath, managedRoots))) {
      throw new Error("Only songs stored in the managed Resonance library can be batch uploaded.");
    }
  } else {
    throw new Error("File uploads are no longer accepted. Download a song from a link first, then upload its preserved source link.");
  }
  const rawAssociationConflictPaths = Array.isArray(associationConflictPaths) ? associationConflictPaths : [];
  if (rawAssociationConflictPaths.length > 50_000) {
    throw new Error("The local library is too large to verify this manual upload safely.");
  }
  const normalizedAssociationConflictPaths = new Set(rawAssociationConflictPaths.flatMap((value) => {
    const candidate = typeof value === "string" ? value.trim() : "";
    return candidate ? [path.resolve(candidate).toLowerCase()] : [];
  }));
  if (requestedFiles.some((item) => normalizedAssociationConflictPaths.has(path.resolve(item.filePath).toLowerCase()))) {
    throw new Error("A selected song is already linked to a different server or profile. Switch back to its original server and profile; Resonance did not upload any selected files.");
  }
  const controller = beginServerTransfer(event);
  const { signal } = controller;
  let uploaded = 0;
  let duplicates = 0;
  let completed = 0;
  const results = [];
  const failed = [];
  const attemptsByRetryID = new Map();
  const completedRetryIDs = new Set();
  const rememberRetry = (item) => {
    const record = safeServerUploadRetryRecord(item);
    if (record) serverUploadRetries.set(record.retryID, record);
  };
  try {
  for (const item of requestedFiles) {
    signal.throwIfAborted();
    const filePath = item.filePath;
    const filename = item.uploadFilename || serverUploadFilename(filePath, item.title);
    event.sender.send("server:transfer-progress", { direction: "upload", currentFile: filename, completed, total: requestedFiles.length, autoHide: false });
    let remoteSong = null;
    let duplicate = false;
    let lastError = null;
    let attempts = 0;
    while (attempts < 3 && !remoteSong) {
      attempts += 1;
      attemptsByRetryID.set(item.retryID, attempts);
      const url = new URL("api/v1/admin/songs", base);
      try {
        await requireClientUploadMode({
          baseURL: base.href,
          token: String(adminToken),
          profileID: requestedProfileID,
          mode: "local_file",
          force: true,
        });
        signal.throwIfAborted();
        const response = await putSourceLinkRegistration({
          base,
          url,
          headers: {
            ...profileHeaders(adminToken, requestedProfileID),
            ...requestContext.expected.request_headers,
            "Content-Type": "application/json",
            Accept: "application/json",
          },
          item,
          signal,
        });
        if (response.status === 201 || response.status === 409) {
          invalidateServerCatalogSnapshots(base, requestedProfileID);
        }
        ({ song: remoteSong, duplicate } = await readServerUploadResponse(response, { serverOrigin: base.origin }));
      } catch (error) {
        if (signal.aborted || error?.name === "AbortError") throw error;
        lastError = error;
        if (error?.retryable === false) throw error;
        if (attempts < 3) await new Promise((resolve) => setTimeout(resolve, attempts === 1 ? 400 : 1200));
      }
    }
    if (remoteSong) {
      uploaded += 1;
      if (duplicate) duplicates += 1;
      completedRetryIDs.add(item.retryID);
      serverUploadRetries.delete(item.retryID);
      results.push({
        retryID: item.retryID,
        trackID: item.trackID || null,
        filePath,
        title: item.title || path.basename(filename, path.extname(filename)),
        artist: item.artist || "",
        filename,
        attempts,
        duplicate,
        remoteSong,
      });
    } else {
      completedRetryIDs.add(item.retryID);
      rememberRetry(item);
      failed.push({ retryID: item.retryID, trackID: item.trackID || null, title: item.title || path.basename(filename, path.extname(filename)), artist: item.artist, filename, attempts, status: "failed", message: lastError?.message || "Upload failed." });
    }
    completed += 1;
    event.sender.send("server:transfer-progress", { direction: "upload", currentFile: filename, completed, total: requestedFiles.length, autoHide: false });
  }
  await persistServerUploadRetries().catch((error) => console.error("Could not persist server upload retries", error));
  return { uploaded, duplicates, results, failed };
  } catch (error) {
    if (error?.name === "AbortError" || signal.aborted) {
      for (const item of requestedFiles) {
        if (completedRetryIDs.has(item.retryID)) continue;
        rememberRetry(item);
        failed.push({
          retryID: item.retryID,
          trackID: item.trackID || null,
          title: item.title || path.basename(item.uploadFilename || item.filePath, path.extname(item.uploadFilename || item.filePath)),
          artist: item.artist || "",
          filename: item.uploadFilename || path.basename(item.filePath),
          attempts: attemptsByRetryID.get(item.retryID) || 0,
          status: "cancelled",
          message: "Upload cancelled.",
        });
      }
      await persistServerUploadRetries().catch((persistError) => console.error("Could not persist server upload retries", persistError));
      return { uploaded, duplicates, results, failed, cancelled: true };
    }
    if (error?.retryable === false) {
      const blockedEntries = policyBlockedUploadEntries(
        requestedFiles,
        completedRetryIDs,
        attemptsByRetryID,
        error.message,
      );
      for (const { item, failure } of blockedEntries) {
        completedRetryIDs.add(item.retryID);
        rememberRetry(item);
        failed.push(failure);
      }
      await persistServerUploadRetries().catch((persistError) => console.error("Could not persist server upload retries", persistError));
      event.sender.send("server:transfer-progress", {
        direction: "upload",
        currentFile: "Uploads stopped by server policy",
        completed: requestedFiles.length,
        total: requestedFiles.length,
        autoHide: false,
      });
      return { uploaded, duplicates, results, failed, policyBlocked: true };
    }
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

ipcMain.handle("server:upload:discard-retries", async (_event, { baseURL, profileID, retryIDs } = {}) => {
  const base = normalizeBaseURL(baseURL);
  const requestedProfileID = String(profileID || "default");
  await ensureServerUploadRetriesLoaded();
  let removed = 0;
  for (const retryID of [...new Set((Array.isArray(retryIDs) ? retryIDs : []).map((value) => String(value || "").trim()).filter(Boolean))].slice(0, MAX_SERVER_UPLOAD_RETRY_RECORDS)) {
    const record = serverUploadRetries.get(retryID);
    if (record?.serverOrigin !== base.origin || record.profileID !== requestedProfileID) continue;
    serverUploadRetries.delete(retryID);
    removed += 1;
  }
  if (removed) await persistServerUploadRetries();
  return removed;
});

ipcMain.handle("server:delete", async (_event, { baseURL, adminToken, profileID, songID }) => {
  const base = normalizeBaseURL(baseURL);
  const encodedSongID = encodeURIComponent(String(songID || ""));
  if (!encodedSongID) throw new Error("Choose a server song to delete.");
  const response = await fetchSameOrigin(base, new URL(`api/v1/admin/songs/${encodedSongID}`, base), { method: "DELETE", headers: profileHeaders(adminToken, profileID) });
  if (!response.ok) {
    const payload = await readResponseJSON(response, MAX_SERVER_ERROR_RESPONSE_BYTES, "Server delete response")
      .catch(() => ({}));
    throw new Error(payload?.error || `Server returned HTTP ${response.status}`);
  }
  invalidateServerCatalogSnapshots(base, profileID);
  return true;
});

ipcMain.handle("server:open-admin", async (_event, baseURL) => {
  const base = normalizeBaseURL(baseURL);
  await shell.openExternal(new URL("admin", base).href);
});

module.exports = { safeFilename, normalizeBaseURL, publicTrack };
