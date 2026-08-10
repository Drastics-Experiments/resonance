import {
  activeServerClientConfig,
  applyRemotePlaylistDocument,
  buildLocalImportSourceIdentity,
  canonicalYouTubeSourcePageURL,
  catalogRequestCanApply,
  clientConfigRenewalDelay,
  createEmptyState,
  exactYouTubeSourcePageURL,
  filterPlaylists,
  filterTracks,
  formatServerDownloadFailureNotice,
  formatServerUploadFailureNotice,
  formatHistoryWindowLabel,
  formatTime,
  isInstalledVideoTrack,
  listeningHistoryEntryQualifiesAsPlay,
  localImportCandidateCanAutoSelect,
  localImportOperationFingerprint,
  localImportOperationIsCurrent,
  localImportNeedsServerContext,
  mergeListeningHistoryDocument,
  mergePlaylistDocument,
  mergeSyncedTracks,
  mergeTrackSourceIdentity,
  mergeUploadedSongsIntoCatalog,
  nextIndex,
  niceChartMaximum,
  normalizeServerUploadManifest,
  normalizedAppPreferences,
  normalizedVolume,
  playbackGainForVolume,
  normalizeState,
  playbackRangeForTrack,
  persistentPlaybackIDs,
  physicalStorageClassForTrack,
  planMissingDownloadedUploads,
  playlistArtworkTrackIDs,
  playlistInsertionIndex,
  preservedUploadSourceURL,
  remoteAssociationConflictFilePaths,
  remoteAssociationConflictMessage,
  reconcileUploadedTrack,
  reorderPlaylistTrackIDs,
  resolveServerTransferModes,
  removeClipRangeForTrack,
  resolveSyncProfile,
  restoreProfileState,
  migrateProfileContext,
  SAFE_CLIENT_CONFIG,
  serverUploadBlockedByActivity,
  serverUploadConfigurationError,
  serverTrackRemoteIDBelongsToContext,
  serverSongRequiresDownload,
  serverSourceDisplayFallback,
  serverSourceNeedsOriginalPage,
  serverUploadManifestRetryIDs,
  shuffledTrackIDs,
  storeActiveProfileState,
  setClipRangeForTrack,
  setServerTransferPreference,
  squareArtworkCropRect,
  summarizeListeningHistory,
  summarizeListeningStats,
  titleMarqueeMetrics,
  trackBelongsToActiveProfile,
  tracksForActiveProfile,
  tracksForPlaylist,
  updatePlaylistRemoteSongIDs,
} from "./core.js";

const api = window.resonance;
const audio = document.querySelector("#audio");
const clipEditorPreviewAudio = document.querySelector("#clipEditorPreview");
const clipEditorVisualizerCanvas = document.querySelector("#clipEditorStageVisualizerCanvas");
const clipEditorVisualizerContext = clipEditorVisualizerCanvas.getContext("2d", { alpha: true, desynchronized: true });
const installedVideoPlayer = document.querySelector("#installedVideoPlayer");
const localImportPreviewAudio = document.querySelector("#localImportPreview");
const content = document.querySelector("#content");
let state = createEmptyState();
let currentID = null;
let section = "library";
let selectedPlaylistID = null;
let libraryFilter = "all";
let serverToken = "";
let serverAdminToken = "";
let accountSession = null;
let isAccountEmailRevealed = false;
let serverCatalog = [];
let serverCatalogGeneration = 0;
const serverArtworkCache = new Map();
const serverArtworkPending = new Map();
const squareArtworkCache = new Map();
const squareArtworkPending = new Map();
let selectedRemoteIDs = new Set();
let shuffle = false;
let repeat = false;
let history = [];
let fullPlayerQueueTab = "up-next";
let activePlaybackQueueIDs = [];
let activePlaybackSourceQueueIDs = [];
let activePlaybackPlaylistID = null;
let pendingRestorePosition = null;
let playbackProgressTimer = null;
let playbackProgressAnimationFrame = null;
let activeListeningEntryID = null;
let lastListeningPosition = 0;
let lastPersistedListeningSeconds = 0;
let listeningHistorySyncTimer = null;
let listeningHistorySyncInFlight = null;
let listeningHistorySyncPending = false;
let listeningHistoryRetryAt = 0;
const listeningHistorySyncedSeconds = new Map();
const LISTENING_HISTORY_BATCH_SIZE = 500;
const LISTENING_HISTORY_RETRY_DELAY = 60000;
let listeningHistoryMode = "overall";
let listeningHistoryWindowOffset = 0;
let selectedListeningHistoryDayKey = null;
let listeningHistorySongsExpanded = false;
let appNoticeDismissTimer = null;
const APP_NOTICE_LIFETIME_MS = 5000;
let nowPlayingCloseTimer = null;
let fullPlayerTitleMarqueeFrame = null;
let audioSourceTrackID = null;
let audioMetadataTrackID = null;
let installedVideoSession = null;
let installedVideoTransitionTimer = null;
let installedVideoGeometryAnimation = null;
let installedVideoChromeTimer = null;
let installedVideoArtworkTimer = null;
let installedVideoControlsTimer = null;
const FULL_PLAYER_TRANSITION_MS = 380;
const INSTALLED_VIDEO_LEAD_IN_MS = 35;
const INSTALLED_VIDEO_TRANSITION_MS = 400;
const INSTALLED_VIDEO_REVEAL_MS = 140;
const INSTALLED_VIDEO_EXIT_ARTWORK_LEAD_MS = 190;
const INSTALLED_VIDEO_CHROME_RESTORE_LEAD_MS = 120;
const INSTALLED_VIDEO_CONTROLS_TIMEOUT_MS = 2200;
const INSTALLED_VIDEO_SYNC_TOLERANCE_SECONDS = 0.12;
let navigationHistory = [{ section: "library", playlistID: null }];
let navigationIndex = 0;
let pendingPlaylistTrackID = null;
let addSongsPlaylistID = null;
let libraryQuery = "";
let playlistQuery = "";
let recentlyAddedScrollLeft = 0;
let playlistSyncInFlight = null;
let playlistSyncPending = false;
let playlistSyncTimer = null;
let playlistMutationGeneration = 0;
let likesMutationGeneration = 0;
let clipRangeMutationGeneration = 0;
let storageScope = "songs";
let storageQuery = "";
let storageSort = "title";
let storageEditing = false;
let selectedStorageIDs = new Set();
let serverQuery = "";
let serverScope = "all";
let serverSort = "title";
let serverSelecting = false;
let serverConnectionText = "Not connected";
let serverConnected = false;
let clientConfig = SAFE_CLIENT_CONFIG;
let clientConfigRequestGeneration = 0;
let clientConfigRenewalTimer = null;
let activeServerStream = null;
let serverStreamRequestGeneration = 0;
let serverConnectInFlight = false;
let serverConnectPending = false;
let serverAutoAttempted = false;
let serverTransferActive = false;
let serverTransferCancelRequested = false;
let serverTransferOwner = null;
let serverContextReservation = null;
let draggingPlaylistTrackID = null;
let draggingPlaylistTargetID = null;
let draggingPlaylistInsertAfter = false;
let playlistDragPreviewKey = "";
let playlistDragFloatingRow = null;
let playlistPointerDrag = null;
let suppressPlaylistRowClickUntil = 0;
let localImportAvailable = false;
let localImportResolution = null;
let localImportRunning = false;
let localImportArtworkRequest = 0;
let localImportKeepStateOnClose = false;
let localImportPreviewIndex = null;
let localImportPreviewLoadingIndex = null;
let localImportPreviewRequest = 0;
let localImportPreviewLimitSeconds = 30;
let localImportPreviewInterruptedPlayback = false;
let localImportAutoResolveTimer = null;
let localImportResolutionRestartPending = false;
let localImportResolvedSourceKey = null;
let localImportInteractionGeneration = 0;
let localImportBatchContext = null;
let localImportServerUploadMode = null;
let localImportProviderFocus = "youtube";
let availableWindowsUpdateVersion = null;
let dismissedWindowsUpdateVersion = null;
let windowsUpdateReady = false;
const LOCAL_IMPORT_AUTO_RESOLVE_DELAY = 450;
const LOCAL_IMPORT_PROVIDER_ORDER = Object.freeze([
  ["youtube", "YouTube"],
  ["spotify", "Spotify"],
  ["soundcloud", "SoundCloud"],
]);
let clipEditorStartSeconds = 0;
let clipEditorEndSeconds = 30;
let clipEditorPreviewEndSeconds = 0;
let clipEditorPreviewInterruptedPlayback = false;
let clipEditorPreviewLoading = false;
let clipEditorPreviewRequest = 0;
let clipEditorWaveformRequest = 0;
let clipEditorVideoFrameRequest = 0;
let clipEditorVisualizerFrame = 0;
const CLIP_EDITOR_VISUALIZER_BAR_COUNT = 112;
let clipEditorVisualizerPreviousTimestamp = 0;
let clipEditorVisualizerBinRanges = null;
let clipEditorVisualizerStaticLevels = new Float32Array(CLIP_EDITOR_VISUALIZER_BAR_COUNT).fill(.08);
let clipEditorVisualizerDisplayedLevels = new Float32Array(CLIP_EDITOR_VISUALIZER_BAR_COUNT);
let clipEditorVisualizerTargetLevels = new Float32Array(CLIP_EDITOR_VISUALIZER_BAR_COUNT);
let clipEditorVisualizerGradient = null;
let clipEditorVisualizerGradientSize = "";
let clipEditorAudioContext = null;
let clipEditorAudioSource = null;
let clipEditorAnalyser = null;
let clipEditorAnalyserData = null;
let clipEditorSavedStartSeconds = 0;
let clipEditorSavedEndSeconds = 0;
let clipBoundaryTrackID = null;
let profileGeneration = 0;
let activeProfilePicture = null;
let settingsPanel = "general";
let settingsRecordingAction = null;
let discordPresenceStatus = { state: "disabled", message: "Rich Presence is off.", applicationConfigured: false };
let discordPresenceSyncTimer = null;
const activeProfileID = () => state.syncProfileID || "default";

const settingsKeybindActions = Object.freeze({
  togglePlayback: { label: "Play / pause", description: "Toggle playback from anywhere in Resonance." },
  previousTrack: { label: "Previous track", description: "Return to the previous song in the queue." },
  nextTrack: { label: "Next track", description: "Advance to the next song in the queue." },
  volumeDown: { label: "Volume down", description: "Lower playback volume by five percent." },
  volumeUp: { label: "Volume up", description: "Raise playback volume by five percent." },
});

function settingsIcon(pathMarkup) {
  return `<svg viewBox="0 0 24 24" aria-hidden="true">${pathMarkup}</svg>`;
}

const settingsIcons = Object.freeze({
  general: settingsIcon('<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.8 1.8 0 0 0 .36 2l.07.07-2.76 2.76-.07-.07a1.8 1.8 0 0 0-2-.36 1.8 1.8 0 0 0-1.1 1.65V21h-3.8v-.1A1.8 1.8 0 0 0 9 19.25a1.8 1.8 0 0 0-2 .36l-.07.07-2.76-2.76.07-.07a1.8 1.8 0 0 0 .36-2A1.8 1.8 0 0 0 2.95 13H3v-3.8h-.05A1.8 1.8 0 0 0 4.6 8a1.8 1.8 0 0 0-.36-2l-.07-.07 2.76-2.76.07.07a1.8 1.8 0 0 0 2 .36A1.8 1.8 0 0 0 10.1 2H14v.05A1.8 1.8 0 0 0 15 3.7a1.8 1.8 0 0 0 2-.36l.07-.07 2.76 2.76-.07.07a1.8 1.8 0 0 0-.36 2A1.8 1.8 0 0 0 21.05 9H21v4h.05A1.8 1.8 0 0 0 19.4 15Z"/>'),
  server: settingsIcon('<circle cx="12" cy="12" r="8"/><path d="M4.5 9h15M4.5 15h15M12 4c2 2.2 3 4.9 3 8s-1 5.8-3 8c-2-2.2-3-4.9-3-8s1-5.8 3-8Z"/>'),
  keybinds: settingsIcon('<rect x="3" y="6" width="18" height="13" rx="2"/><path d="M7 10h.01M11 10h.01M15 10h.01M7 14h.01M11 14h6M18 10h.01"/>'),
  background: settingsIcon('<path d="M4 7h16v11H4z"/><path d="M8 7V4h8v3M8 21h8"/>'),
  discord: settingsIcon('<path d="M7.5 7.4A11 11 0 0 1 12 6.5a11 11 0 0 1 4.5.9c1.1 1.5 2 4.4 2 6.4-1.3 1.6-2.6 2.2-4 2.6l-1-1.3M16.5 7.4l.9-1.7M7.5 7.4l-.9-1.7M10 13h.01M14 13h.01M9.5 15.1c1.7.7 3.3.7 5 0"/>'),
  update: settingsIcon('<path d="M20 12a8 8 0 1 1-2.34-5.66"/><path d="M20 4v6h-6"/>'),
});

const serverUploadModeOptions = Object.freeze({
  local_file: "Preserved source links",
  server_source_link: "Preserved source links",
  reviewed_match: "Reviewed source links",
});
const serverDownloadModeOptions = Object.freeze({
  verified_file_cache: "Verified files on this device",
  stream_only: "Stream only",
});

const $ = (selector) => document.querySelector(selector);

function rememberSquareArtwork(source, cropped) {
  if (squareArtworkCache.size >= 256) squareArtworkCache.delete(squareArtworkCache.keys().next().value);
  squareArtworkCache.set(source, cropped);
  return cropped;
}

async function squareArtworkSource(value) {
  const source = String(value || "");
  if (!source) return source;
  if (squareArtworkCache.has(source)) return squareArtworkCache.get(source);
  if (squareArtworkPending.has(source)) return squareArtworkPending.get(source);

  const pending = (async () => {
    const image = new Image();
    image.decoding = "async";
    await new Promise((resolve, reject) => {
      image.onload = resolve;
      image.onerror = reject;
      image.src = source;
    });
    const naturalWidth = image.naturalWidth;
    const naturalHeight = image.naturalHeight;
    if (!(naturalWidth > 0 && naturalHeight > 0)) return source;

    const sampleScale = Math.min(1, 160 / Math.max(naturalWidth, naturalHeight));
    const sampleWidth = Math.max(1, Math.round(naturalWidth * sampleScale));
    const sampleHeight = Math.max(1, Math.round(naturalHeight * sampleScale));
    const sample = document.createElement("canvas");
    sample.width = sampleWidth;
    sample.height = sampleHeight;
    const sampleContext = sample.getContext("2d", { willReadFrequently: true });
    if (!sampleContext) return source;
    sampleContext.drawImage(image, 0, 0, sampleWidth, sampleHeight);
    const pixels = sampleContext.getImageData(0, 0, sampleWidth, sampleHeight).data;
    const crop = squareArtworkCropRect(pixels, sampleWidth, sampleHeight, naturalWidth, naturalHeight);
    const isUnchangedSquare = naturalWidth === naturalHeight
      && Math.abs(crop.x) < 0.5
      && Math.abs(crop.y) < 0.5
      && Math.abs(crop.width - naturalWidth) < 0.5
      && Math.abs(crop.height - naturalHeight) < 0.5;
    if (isUnchangedSquare) return source;

    const outputSize = Math.max(1, Math.min(1024, Math.round(crop.width)));
    const output = document.createElement("canvas");
    output.width = outputSize;
    output.height = outputSize;
    const outputContext = output.getContext("2d");
    if (!outputContext) return source;
    outputContext.imageSmoothingEnabled = true;
    outputContext.imageSmoothingQuality = "high";
    outputContext.drawImage(
      image,
      crop.x,
      crop.y,
      crop.width,
      crop.height,
      0,
      0,
      outputSize,
      outputSize,
    );
    return output.toDataURL("image/png");
  })().catch(() => source).then((cropped) => rememberSquareArtwork(source, cropped));
  squareArtworkPending.set(source, pending);
  try {
    return await pending;
  } finally {
    if (squareArtworkPending.get(source) === pending) squareArtworkPending.delete(source);
  }
}

function squareArtworkImageMarkup(source, alt = "") {
  const displaySource = squareArtworkCache.get(String(source || "")) || source;
  return `<img data-square-artwork src="${escapeHTML(displaySource)}" alt="${escapeHTML(alt)}">`;
}

function bindSquareArtworkImage(image) {
  if (!(image instanceof HTMLImageElement)
      || !image.hasAttribute("data-square-artwork")
      || image.dataset.squareArtworkProcessed) return;
  const source = image.currentSrc || image.src;
  if (!source) return;
  image.dataset.squareArtworkProcessed = "pending";
  void squareArtworkSource(source).then((cropped) => {
    if ((image.currentSrc || image.src) !== source) return;
    image.dataset.squareArtworkProcessed = "true";
    if (cropped !== source) image.src = cropped;
  });
}

function bindSquareArtworkImages(root = document) {
  root.querySelectorAll("img[data-square-artwork]").forEach((image) => {
    if (image.complete && image.naturalWidth > 0) bindSquareArtworkImage(image);
    else image.addEventListener("load", () => bindSquareArtworkImage(image), { once: true });
  });
}

document.addEventListener("load", (event) => {
  bindSquareArtworkImage(event.target);
}, true);
const shuffleIcon = `<svg class="shuffle-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h2.5a5 5 0 0 1 4 2l5 7a5 5 0 0 0 4 2H21"/><path d="m17 13 4 4-4 4"/><path d="M3 18h2.5a5 5 0 0 0 4-2l5-7a5 5 0 0 1 4-2H21"/><path d="m17 3 4 4-4 4"/></svg>`;
const plusIcon = `<svg class="plus-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>`;
const checkIcon = `<svg class="check-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="m5 12.5 4.3 4.3L19 7"/></svg>`;
const playbackPlayIcon = `<svg class="transport-icon" viewBox="0 0 24 24" aria-hidden="true"><path class="icon-fill" d="M8 5v14l11-7z"/></svg>`;
const playbackPauseIcon = `<svg class="transport-icon" viewBox="0 0 24 24" aria-hidden="true"><rect class="icon-fill" x="6" y="5" width="4.5" height="14" rx="1.5"/><rect class="icon-fill" x="13.5" y="5" width="4.5" height="14" rx="1.5"/></svg>`;
const nowPlayingIcon = `<svg class="now-playing-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M3.5 9.5h4l5-4v13l-5-4h-4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7"/><path d="M18.5 5.5a9 9 0 0 1 0 13"/></svg>`;
const serverUploadIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 16V4m0 0L7.5 8.5M12 4l4.5 4.5"/><path d="M5 14v5h14v-5"/></svg>`;
const serverUploadMissingIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 16V5m0 0L8 9m4-4 4 4"/><path d="M6 18.5h12"/><path d="M5 13a4 4 0 0 1 3.8-4A5 5 0 0 1 18 10.5a3.5 3.5 0 0 1-.5 7"/></svg>`;
const serverDownloadIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 4v12m0 0 4.5-4.5M12 16l-4.5-4.5"/><path d="M5 19h14"/></svg>`;
const serverSelectIcon = `<svg class="server-selection-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="m3.5 7 2 2 4-4"/><path d="M13 6h8"/><path d="m3.5 17 2 2 4-4"/><path d="M13 16h8"/></svg>`;
const serverPlaylistIcon = `<svg class="server-playlist-sync-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M21 12a9 9 0 0 0-15.1-6.6L3 8"/><path d="M3 3v5h5"/><path d="M3 12a9 9 0 0 0 15.1 6.6L21 16"/><path d="M21 21v-5h-5"/></svg>`;
const serverSongIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="9" cy="18" r="3"/><path d="M12 18V5l8-2v13"/><circle cx="17" cy="16" r="3"/></svg>`;
const serverPlaylistMetricIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 6h10M4 11h10M4 16h7"/><circle cx="17" cy="17" r="3"/><path d="M20 17V7l-6 1.5"/></svg>`;
const serverDeviceIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m5 12 4 4L19 6"/></svg>`;
const historyClockIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/></svg>`;
const historyPlaysIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 12h2m2-5v10m3-13v16m3-11v6m3-9v12m3-7v2"/></svg>`;
const historyTodayIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 18V7l9-2v11"/><circle cx="6.5" cy="18" r="2.5"/><circle cx="15.5" cy="16" r="2.5"/></svg>`;
const historyLibraryIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 7h7l2 2h9v10H3z"/><path d="M3 7V5h7l2 2"/></svg>`;
const contextPlayIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path class="context-icon-fill" d="M8 5v14l11-7z"/></svg>`;
const contextVideoIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="6" width="13" height="12" rx="2"/><path d="m16 10 5-3v10l-5-3z"/></svg>`;
const contextPauseIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 6v12M16 6v12"/></svg>`;
const contextHeartIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20.8 5.8a5.2 5.2 0 0 0-7.4 0L12 7.2l-1.4-1.4a5.2 5.2 0 1 0-7.4 7.4L12 22l8.8-8.8a5.2 5.2 0 0 0 0-7.4Z"/></svg>`;
const contextPlaylistIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 6h10M4 11h10M4 16h7"/><path d="M18 13v7M14.5 16.5h7"/></svg>`;
const contextRemoveIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12h14"/></svg>`;
const contextTrashIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16M9 3h6l1 4M7 7l1 14h8l1-14M10 11v6M14 11v6"/></svg>`;
const contextDownloadIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 4v11m0 0 4-4m-4 4-4-4M5 20h14"/></svg>`;
const contextOpenIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12h14m-5-5 5 5-5 5"/></svg>`;
const contextBackIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M19 12H5m5-5-5 5 5 5"/></svg>`;
const escapeHTML = (value) => String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" }[character]));
const playbackSpeedOptions = [
  { value: "0.75", label: "0.75×" },
  { value: "1", label: "1×" },
  { value: "1.25", label: "1.25×" },
  { value: "1.5", label: "1.5×" },
  { value: "2", label: "2×" },
];
const customSelectInitialOptions = {
  speed: playbackSpeedOptions,
  fullPlayerSpeed: playbackSpeedOptions,
  listeningHistoryRange: [
    { value: "1", label: "Last 1 day" },
    { value: "7", label: "Last 7 days" },
    { value: "30", label: "Last 30 days" },
    { value: "90", label: "Last 90 days" },
  ],
};
const customSelectControllers = new Map();

function positionCustomSelect(controller) {
  if (!controller?.root.classList.contains("open")) return;
  const { root, trigger, menu } = controller;
  const rectangle = trigger.getBoundingClientRect();
  const openDialog = root.closest("dialog[open]");
  const minimumWidth = Number(root.dataset.customSelectWidth) || 0;
  const width = Math.min(window.innerWidth - 16, Math.max(rectangle.width, minimumWidth));
  menu.style.width = `${width}px`;
  const measuredHeight = Math.min(menu.scrollHeight, Math.max(120, window.innerHeight - 20));
  const roomBelow = window.innerHeight - rectangle.bottom - 8;
  const roomAbove = rectangle.top - 8;
  const openAbove = roomBelow < Math.min(measuredHeight, 190) && roomAbove > roomBelow;
  menu.classList.toggle("opens-up", openAbove);
  menu.classList.toggle("dialog-contained", Boolean(openDialog));
  if (openDialog) {
    const dialogRectangle = openDialog.getBoundingClientRect();
    const left = Math.max(dialogRectangle.left + 8, Math.min(dialogRectangle.right - width - 8, rectangle.left));
    const top = Math.max(dialogRectangle.top + 8, openAbove
      ? rectangle.top - measuredHeight - 6
      : Math.min(dialogRectangle.bottom - measuredHeight - 8, rectangle.bottom + 6));
    menu.style.left = `${left - dialogRectangle.left}px`;
    menu.style.top = `${top - dialogRectangle.top}px`;
    return;
  }
  menu.style.left = `${Math.max(8, Math.min(window.innerWidth - width - 8, rectangle.left))}px`;
  menu.style.top = `${Math.max(8, openAbove
    ? rectangle.top - measuredHeight - 6
    : Math.min(window.innerHeight - measuredHeight - 8, rectangle.bottom + 6))}px`;
}

function closeCustomSelect(control, { restoreFocus = false } = {}) {
  const controller = customSelectControllers.get(control);
  if (!controller || !controller.root.classList.contains("open")) return;
  controller.root.classList.remove("open");
  controller.trigger.setAttribute("aria-expanded", "false");
  controller.menu.hidden = true;
  controller.menu.classList.remove("dialog-contained");
  if (controller.menu.parentElement !== controller.root) controller.root.append(controller.menu);
  if (restoreFocus) controller.trigger.focus();
}

function closeAllCustomSelects(except = null) {
  customSelectControllers.forEach((controller, control) => {
    if (control !== except) closeCustomSelect(control);
  });
}

function customSelectButtons(controller) {
  return [...controller.menu.querySelectorAll("[role=option]:not(:disabled)")];
}

function focusCustomSelectOption(controller, requestedIndex) {
  const buttons = customSelectButtons(controller);
  if (!buttons.length) return;
  const currentIndex = buttons.indexOf(document.activeElement);
  const selectedIndex = buttons.findIndex((button) => button.getAttribute("aria-selected") === "true");
  const baseIndex = currentIndex >= 0 ? currentIndex : Math.max(0, selectedIndex);
  const nextIndex = requestedIndex === "first"
    ? 0
    : requestedIndex === "last"
      ? buttons.length - 1
      : (baseIndex + requestedIndex + buttons.length) % buttons.length;
  buttons[nextIndex].focus();
}

function refreshCustomSelect(control) {
  const controller = customSelectControllers.get(control);
  if (!controller) return;
  const selectedOption = controller.options.find((option) => option.value === controller.currentValue) || controller.options[0];
  if (selectedOption) controller.currentValue = selectedOption.value;
  controller.value.textContent = selectedOption?.triggerLabel || selectedOption?.label || "Choose…";
  controller.trigger.disabled = controller.disabled || !controller.options.length;
  controller.root.classList.toggle("disabled", controller.trigger.disabled);
  controller.root.dataset.value = controller.currentValue;
  controller.menu.replaceChildren(...controller.options.map((option) => {
    const button = document.createElement("button");
    const selected = option === selectedOption;
    button.type = "button";
    button.className = "resonance-select-option";
    button.dataset.value = option.value;
    button.setAttribute("role", "option");
    button.setAttribute("aria-selected", String(selected));
    button.disabled = option.disabled;
    if (selected) button.classList.add("selected");
    const label = document.createElement("span");
    label.textContent = option.label;
    const check = document.createElement("svg");
    check.setAttribute("viewBox", "0 0 16 16");
    check.setAttribute("aria-hidden", "true");
    check.innerHTML = '<path d="m3.5 8.5 3 3 6-7"/>';
    button.append(label, check);
    return button;
  }));
  if (controller.root.classList.contains("open")) requestAnimationFrame(() => positionCustomSelect(controller));
}

function setCustomSelectOptions(control, options, selectedValue = control?.value) {
  const controller = customSelectControllers.get(control);
  if (!controller) return;
  controller.options = (Array.isArray(options) ? options : []).map((option) => ({
    value: String(option?.value ?? ""),
    label: String(option?.label ?? option?.value ?? ""),
    triggerLabel: String(option?.triggerLabel ?? ""),
    disabled: Boolean(option?.disabled),
  }));
  const requestedValue = String(selectedValue ?? "");
  controller.currentValue = controller.options.some((option) => option.value === requestedValue)
    ? requestedValue
    : controller.options[0]?.value || "";
  refreshCustomSelect(control);
}

function setCustomSelectValue(control, value) {
  if (!control) return;
  control.value = String(value ?? "");
}

function openCustomSelect(control, focusDirection = 0) {
  const controller = customSelectControllers.get(control);
  if (!controller || controller.trigger.disabled) return;
  closeAllCustomSelects(control);
  const openDialog = controller.root.closest("dialog[open]");
  if (openDialog) openDialog.append(controller.menu);
  controller.root.classList.add("open");
  controller.trigger.setAttribute("aria-expanded", "true");
  controller.menu.hidden = false;
  positionCustomSelect(controller);
  if (focusDirection) requestAnimationFrame(() => focusCustomSelectOption(controller, focusDirection));
}

function initializeCustomSelect(root) {
  if (!root || customSelectControllers.has(root)) return;
  const trigger = document.createElement("button");
  const value = document.createElement("span");
  const chevron = document.createElement("svg");
  const menu = document.createElement("div");
  const controlName = root.id || `resonanceSelect${customSelectControllers.size + 1}`;
  const accessibleLabel = root.getAttribute("aria-label") || "Choose an option";
  const labelledBy = root.getAttribute("aria-labelledby");
  root.classList.add("resonance-select");
  trigger.id = `${controlName}Button`;
  trigger.type = "button";
  trigger.className = "resonance-select-trigger";
  trigger.setAttribute("aria-haspopup", "listbox");
  trigger.setAttribute("aria-expanded", "false");
  trigger.setAttribute("aria-controls", `${controlName}Menu`);
  if (labelledBy) trigger.setAttribute("aria-labelledby", labelledBy);
  else trigger.setAttribute("aria-label", accessibleLabel);
  value.className = "resonance-select-value";
  chevron.classList.add("resonance-select-chevron");
  chevron.setAttribute("viewBox", "0 0 16 16");
  chevron.setAttribute("aria-hidden", "true");
  chevron.innerHTML = '<path d="m4 6 4 4 4-4"/>';
  trigger.append(value, chevron);
  menu.id = `${controlName}Menu`;
  menu.className = "resonance-select-menu";
  menu.setAttribute("role", "listbox");
  if (labelledBy) menu.setAttribute("aria-labelledby", labelledBy);
  else menu.setAttribute("aria-label", accessibleLabel);
  menu.hidden = true;
  root.removeAttribute("aria-label");
  root.removeAttribute("aria-labelledby");
  root.replaceChildren(trigger, menu);
  const initialOptions = customSelectInitialOptions[controlName] || [];
  const requestedValue = String(root.dataset.value || initialOptions[0]?.value || "");
  const controller = {
    root,
    trigger,
    value,
    menu,
    options: initialOptions.map((option) => ({ ...option })),
    currentValue: requestedValue,
    disabled: false,
  };
  Object.defineProperties(root, {
    value: {
      configurable: true,
      get: () => controller.currentValue,
      set: (nextValue) => {
        const normalizedValue = String(nextValue ?? "");
        if (controller.currentValue === normalizedValue) return;
        controller.currentValue = normalizedValue;
        refreshCustomSelect(root);
      },
    },
    disabled: {
      configurable: true,
      get: () => controller.disabled,
      set: (nextValue) => {
        controller.disabled = Boolean(nextValue);
        refreshCustomSelect(root);
      },
    },
  });
  customSelectControllers.set(root, controller);
  trigger.onclick = () => {
    if (root.classList.contains("open")) closeCustomSelect(root, { restoreFocus: true });
    else openCustomSelect(root);
  };
  trigger.onkeydown = (event) => {
    if (!["ArrowDown", "ArrowUp", "Home", "End", "Enter", " "].includes(event.key)) return;
    event.preventDefault();
    if (!root.classList.contains("open")) openCustomSelect(root);
    if (event.key === "ArrowDown") focusCustomSelectOption(controller, 1);
    else if (event.key === "ArrowUp") focusCustomSelectOption(controller, -1);
    else if (event.key === "Home") focusCustomSelectOption(controller, "first");
    else if (event.key === "End") focusCustomSelectOption(controller, "last");
    else focusCustomSelectOption(controller, 0);
  };
  menu.onclick = (event) => {
    const option = event.target.closest("[role=option]");
    if (!option || option.disabled) return;
    root.value = option.dataset.value;
    root.dispatchEvent(new Event("input", { bubbles: true }));
    root.dispatchEvent(new Event("change", { bubbles: true }));
    closeCustomSelect(root, { restoreFocus: true });
  };
  menu.onkeydown = (event) => {
    if (event.key === "Escape") {
      event.preventDefault();
      closeCustomSelect(root, { restoreFocus: true });
    } else if (event.key === "ArrowDown") {
      event.preventDefault();
      focusCustomSelectOption(controller, 1);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      focusCustomSelectOption(controller, -1);
    } else if (event.key === "Home") {
      event.preventDefault();
      focusCustomSelectOption(controller, "first");
    } else if (event.key === "End") {
      event.preventDefault();
      focusCustomSelectOption(controller, "last");
    } else if (event.key === "Tab") {
      closeCustomSelect(root);
    }
  };
  refreshCustomSelect(root);
}

function initializeCustomSelects() {
  document.querySelectorAll("[data-custom-select]").forEach(initializeCustomSelect);
  document.addEventListener("pointerdown", (event) => {
    customSelectControllers.forEach((controller, control) => {
      if (!controller.root.contains(event.target) && !controller.menu.contains(event.target)) closeCustomSelect(control);
    });
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") closeAllCustomSelects();
  });
  window.addEventListener("resize", () => customSelectControllers.forEach(positionCustomSelect));
  window.addEventListener("resize", () => {
    if ($("#nowPlayingDialog").open) syncFullPlayerTitleMarquee();
  });
  window.addEventListener("scroll", () => customSelectControllers.forEach(positionCustomSelect), true);
}

function disposeCustomSelects(root) {
  root?.querySelectorAll("[data-custom-select]").forEach((control) => {
    const controller = customSelectControllers.get(control);
    if (!controller) return;
    controller.menu.remove();
    customSelectControllers.delete(control);
  });
}

function playbackTrackByID(trackID) {
  const persistent = state.tracks.find((track) => track.id === trackID && trackBelongsToActiveProfile(state, track));
  if (persistent) return persistent;
  return activeServerStream?.track.id === trackID ? activeServerStream.track : null;
}

function persistentPlaybackQueueIDs(trackIDs) {
  return persistentPlaybackIDs(
    trackIDs,
    state.tracks.filter((track) => trackBelongsToActiveProfile(state, track)),
  );
}

const currentTrack = () => playbackTrackByID(currentID);
const playlistTracks = () => (selectedPlaylistID ? tracksForPlaylist(state, selectedPlaylistID) : tracksForActiveProfile(state))
  .filter((track) => trackBelongsToActiveProfile(state, track));
const activeRemoteTrack = (remoteID) => state.tracks.find((track) => track.remoteID === remoteID && trackBelongsToActiveProfile(state, track));
const activeProfile = () => state.syncProfiles.find((profile) => profile.id === activeProfileID())
  || state.syncProfiles.find((profile) => profile.id === "default")
  || { id: "default", name: "Default" };

function activePlaybackTracks() {
  return activePlaybackQueueIDs
    .map(playbackTrackByID)
    .filter(Boolean);
}

function activePlaybackSourceTracks() {
  return activePlaybackSourceQueueIDs
    .map(playbackTrackByID)
    .filter((track) => track?.available !== false)
    .filter(Boolean);
}

function applyShuffleToPlaybackContext(anchorTrackID = currentID) {
  const sourceTracks = activePlaybackSourceTracks();
  activePlaybackQueueIDs = shuffle
    ? shuffledTrackIDs(sourceTracks, anchorTrackID)
    : sourceTracks.map((track) => track.id);
  state.playbackQueueIDs = persistentPlaybackQueueIDs(activePlaybackQueueIDs);
  state.playbackSourceQueueIDs = persistentPlaybackQueueIDs(activePlaybackSourceQueueIDs);
}

function setShuffleEnabled(value) {
  if (currentTrack()?.transientStream) return false;
  shuffle = Boolean(value);
  state.shuffle = shuffle;
  applyShuffleToPlaybackContext();
  persistInBackground();
  updateChrome();
  return true;
}

function setPlaybackContext(tracks, playlistID, anchorTrackID = currentID) {
  activePlaybackSourceQueueIDs = [...new Set(tracks
    .filter((track) => track?.available !== false)
    .map((track) => track.id))];
  activePlaybackPlaylistID = typeof playlistID === "string" ? playlistID : null;
  applyShuffleToPlaybackContext(anchorTrackID);
  state.playbackPlaylistID = activePlaybackPlaylistID;
}

function isCurrentCollectionPlayback(tracks = playlistTracks()) {
  const viewedPlaylistID = typeof selectedPlaylistID === "string" ? selectedPlaylistID : null;
  return activePlaybackPlaylistID === viewedPlaylistID && tracks.some((track) => track.id === currentID);
}

function showNotice(message, kind = "error") {
  const notice = $("#appNotice");
  if (!notice) return;
  if (appNoticeDismissTimer) clearTimeout(appNoticeDismissTimer);
  $("#appNoticeText").textContent = String(message || "Something went wrong.");
  notice.dataset.kind = kind;
  notice.setAttribute("role", kind === "error" ? "alert" : "status");
  notice.setAttribute("aria-live", kind === "error" ? "assertive" : "polite");
  notice.hidden = false;
  appNoticeDismissTimer = setTimeout(() => {
    appNoticeDismissTimer = null;
    notice.hidden = true;
  }, APP_NOTICE_LIFETIME_MS);
}

function friendlyIPCError(error, fallback) {
  const message = String(error?.message || fallback || "Something went wrong.");
  return message.replace(/^Error invoking remote method '[^']+':\s*(?:Error:\s*)?/, "");
}

function dismissNotice() {
  const notice = $("#appNotice");
  if (appNoticeDismissTimer) {
    clearTimeout(appNoticeDismissTimer);
    appNoticeDismissTimer = null;
  }
  if (notice) notice.hidden = true;
}

function clearPlaylistDragPreview() {
  document.querySelectorAll(".drag-preview-up, .drag-preview-down").forEach((row) => {
    row.classList.remove("drag-preview-up", "drag-preview-down");
    row.style.removeProperty("--playlist-drag-offset");
  });
  playlistDragPreviewKey = "";
}

function clearPlaylistDragFloatingRow() {
  playlistDragFloatingRow?.remove();
  playlistDragFloatingRow = null;
  document.querySelectorAll(".track-row.dragging").forEach((row) => row.classList.remove("dragging"));
}

function startPlaylistDragPreview(row, trackTable) {
  draggingPlaylistTrackID = row.dataset.track;
  draggingPlaylistTargetID = null;
  draggingPlaylistInsertAfter = false;
  clearPlaylistDragPreview();
  clearPlaylistDragFloatingRow();
  row.classList.add("dragging");
  const floatingRow = row.cloneNode(true);
  floatingRow.classList.remove("playlist-draggable", "dragging", "drag-preview-up", "drag-preview-down");
  floatingRow.classList.add("playlist-drag-floating");
  floatingRow.removeAttribute("data-track");
  floatingRow.removeAttribute("data-playlist-draggable");
  floatingRow.removeAttribute("aria-label");
  floatingRow.removeAttribute("aria-keyshortcuts");
  floatingRow.removeAttribute("tabindex");
  floatingRow.setAttribute("aria-hidden", "true");
  floatingRow.style.top = `${row.offsetTop}px`;
  floatingRow.style.left = `${row.offsetLeft}px`;
  floatingRow.style.width = `${row.offsetWidth}px`;
  floatingRow.style.height = `${row.offsetHeight}px`;
  floatingRow.style.setProperty("--playlist-drag-source-offset", "0px");
  trackTable?.append(floatingRow);
  playlistDragFloatingRow = floatingRow;
}

function playlistDragDestination(trackTable, clientY) {
  const rows = [...(trackTable?.querySelectorAll("[data-playlist-draggable]") || [])];
  if (!rows.length) return null;
  const tableTop = trackTable.getBoundingClientRect().top;
  const insertionIndex = playlistInsertionIndex(
    rows.map((row) => tableTop + row.offsetTop + row.offsetHeight / 2),
    clientY,
  );
  if (insertionIndex < 0) return null;
  if (insertionIndex === rows.length) return { targetRow: rows.at(-1), insertAfter: true };
  return { targetRow: rows[insertionIndex], insertAfter: false };
}

function updatePlaylistDragPreview(targetRow, insertAfter = false) {
  if (!draggingPlaylistTrackID) return;
  if (!targetRow || draggingPlaylistTrackID === targetRow.dataset.track) {
    draggingPlaylistTargetID = null;
    draggingPlaylistInsertAfter = false;
    clearPlaylistDragPreview();
    playlistDragFloatingRow?.style.setProperty("--playlist-drag-source-offset", "0px");
    return;
  }
  const previewKey = `${targetRow.dataset.track}:${insertAfter ? "after" : "before"}`;
  draggingPlaylistTargetID = targetRow.dataset.track;
  draggingPlaylistInsertAfter = insertAfter;
  if (previewKey === playlistDragPreviewKey) return;
  clearPlaylistDragPreview();
  playlistDragPreviewKey = previewKey;
  const rows = [...document.querySelectorAll("[data-playlist-draggable]")];
  const sourceIndex = rows.findIndex((item) => item.dataset.track === draggingPlaylistTrackID);
  const targetIndex = rows.indexOf(targetRow);
  if (sourceIndex < 0 || targetIndex < 0) return;
  const destinationIndex = targetIndex + (draggingPlaylistInsertAfter ? 1 : 0) - (sourceIndex < targetIndex ? 1 : 0);
  const endIndex = sourceIndex < targetIndex ? targetIndex - (draggingPlaylistInsertAfter ? 0 : 1) : sourceIndex - 1;
  const startIndex = sourceIndex < targetIndex ? sourceIndex + 1 : targetIndex + (draggingPlaylistInsertAfter ? 1 : 0);
  const previewClass = sourceIndex < targetIndex ? "drag-preview-up" : "drag-preview-down";
  const sourceRow = rows[sourceIndex];
  const adjacentRow = rows[sourceIndex + 1] || rows[sourceIndex - 1];
  const rowPitch = adjacentRow ? Math.abs(adjacentRow.offsetTop - sourceRow.offsetTop) : sourceRow.offsetHeight;
  const destinationTop = rows[destinationIndex]?.offsetTop ?? sourceRow.offsetTop;
  playlistDragFloatingRow?.style.setProperty("--playlist-drag-source-offset", `${destinationTop - sourceRow.offsetTop}px`);
  for (let index = startIndex; index <= endIndex; index += 1) {
    rows[index].classList.add(previewClass);
    rows[index].style.setProperty("--playlist-drag-offset", `${rowPitch}px`);
  }
}

function clearPlaylistPointerDrag() {
  const drag = playlistPointerDrag;
  playlistPointerDrag = null;
  if (drag?.pointerID != null) {
    const sourceRow = document.querySelector(`[data-track="${CSS.escape(drag.sourceID)}"]`);
    if (sourceRow?.hasPointerCapture(drag.pointerID)) sourceRow.releasePointerCapture(drag.pointerID);
  }
  draggingPlaylistTrackID = null;
  draggingPlaylistTargetID = null;
  draggingPlaylistInsertAfter = false;
  clearPlaylistDragFloatingRow();
  clearPlaylistDragPreview();
}

async function commitPlaylistTrackReorder(sourceID, targetID, insertAfter) {
  const playlist = state.playlists.find((item) => item.id === selectedPlaylistID && !item.isSystem);
  if (!playlist) return false;
  const reordered = reorderPlaylistTrackIDs(playlist.trackIDs, sourceID, targetID, insertAfter);
  if (reordered.every((trackID, index) => trackID === playlist.trackIDs[index])) return false;
  playlist.trackIDs = reordered;
  updatePlaylistRemoteSongIDs(state, playlist);
  markPlaylistDirty(playlist);
  if (activePlaybackPlaylistID === playlist.id) setPlaybackContext(tracksForPlaylist(state, playlist.id), playlist.id);
  renderLibrary();
  await persist();
  schedulePlaylistSync();
  return true;
}

function paintProfileAvatar(element, initial) {
  if (!element) return;
  element.textContent = initial;
  element.classList.toggle("profile-avatar-image", Boolean(activeProfilePicture));
  if (activeProfilePicture) element.style.backgroundImage = `url(${JSON.stringify(activeProfilePicture)})`;
  else element.style.removeProperty("background-image");
}

function updateProfileControl() {
  updateProfileControlView();
}

function displayedAccountEmail(email = accountSession?.email) {
  return isAccountEmailRevealed && email ? email : "••••••@••••••.•••";
}

function safeAccountDisplayName(session = accountSession, fallback = "Account") {
  const email = String(session?.email || "").trim();
  const candidate = String(session?.displayName || fallback || "").trim();
  const looksLikeEmail = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(candidate);
  return candidate && !looksLikeEmail && candidate.toLocaleLowerCase() !== email.toLocaleLowerCase()
    ? candidate
    : "Clerk account";
}

function updateProfileControlView({ refreshPicture = true } = {}) {
  const control = $("#profileControl");
  const button = $("#profileButton");
  if (!control || !button) return;
  const name = accountSession
    ? safeAccountDisplayName(accountSession)
    : safeAccountDisplayName(null, activeProfile().name || "Account");
  control.hidden = false;
  button.title = `Profile: ${name}`;
  button.setAttribute("aria-label", `Open profile menu for ${name}`);
  const initial = Array.from(name)[0]?.toLocaleUpperCase() || "D";
  activeProfilePicture = accountSession?.imageURL || null;
  paintProfileAvatar($("#profileInitial"), initial);
  paintProfileAvatar($("#profileMenuInitial"), initial);
  $("#profileMenuName").textContent = name;
  const email = $("#profileMenuEmail");
  email.textContent = accountSession?.email ? displayedAccountEmail() : "Clerk account";
  email.title = accountSession?.email
    ? (isAccountEmailRevealed ? "Click to hide email address" : "Click to reveal email address")
    : "";
  $("#profileMenuManage").setAttribute("aria-label", `Manage ${name} account`);
}

function closeProfileMenu({ restoreFocus = false } = {}) {
  const menu = $("#profileMenu");
  const button = $("#profileButton");
  if (!menu || !button || menu.hidden) return;
  menu.hidden = true;
  button.setAttribute("aria-expanded", "false");
  $("#profileControl")?.classList.remove("open");
  if (restoreFocus) button.focus();
}

function toggleProfileMenu() {
  const menu = $("#profileMenu");
  const button = $("#profileButton");
  if (!menu || !button) return;
  if (!menu.hidden) {
    closeProfileMenu({ restoreFocus: true });
    return;
  }
  updateProfileControl();
  menu.hidden = false;
  button.setAttribute("aria-expanded", "true");
  $("#profileControl")?.classList.add("open");
}

function clipEditorTrack() {
  return tracksForActiveProfile(state).find((track) => track.id === $("#clipEditorTrack").value) || null;
}

function clipEditorDuration(track = clipEditorTrack()) {
  return Math.max(1, Math.round(Number(track?.duration) || 30));
}

function clipEditorTrackIsVideo(track = clipEditorTrack()) {
  const source = String(track?.filePath || track?.fileUrl || "").split(/[?#]/, 1)[0];
  return /\.(?:mp4|mov|m4v|webm)$/i.test(source);
}

function clipEditorWaveBars(levels = []) {
  return Array.from({ length: CLIP_EDITOR_VISUALIZER_BAR_COUNT }, (_, index) => {
    const sourceIndex = levels.length > 1
      ? Math.min(levels.length - 1, Math.round(index / (CLIP_EDITOR_VISUALIZER_BAR_COUNT - 1) * (levels.length - 1)))
      : 0;
    const level = Number.isFinite(levels[sourceIndex]) ? levels[sourceIndex] : .08;
    const height = 10 + Math.round(Math.max(.04, Math.min(1, level)) * 86);
    return `<i style="height:${height}%"></i>`;
  }).join("");
}

function sampledClipEditorVisualizerLevels(levels = []) {
  const sampled = new Float32Array(CLIP_EDITOR_VISUALIZER_BAR_COUNT);
  for (let index = 0; index < sampled.length; index += 1) {
    const sourceIndex = levels.length > 1
      ? Math.min(levels.length - 1, Math.round(index / (sampled.length - 1) * (levels.length - 1)))
      : 0;
    sampled[index] = Number.isFinite(levels[sourceIndex])
      ? Math.max(0, Math.min(1, levels[sourceIndex]))
      : .08;
  }
  return sampled;
}

function drawClipEditorStageVisualizer(levels, { live = false } = {}) {
  const canvas = clipEditorVisualizerCanvas;
  const width = Math.max(0, canvas.clientWidth);
  const height = Math.max(0, canvas.clientHeight);
  if (!width || !height) return;

  const pixelRatio = Math.min(2, Math.max(1, window.devicePixelRatio || 1));
  const pixelWidth = Math.max(1, Math.round(width * pixelRatio));
  const pixelHeight = Math.max(1, Math.round(height * pixelRatio));
  if (canvas.width !== pixelWidth || canvas.height !== pixelHeight) {
    canvas.width = pixelWidth;
    canvas.height = pixelHeight;
    clipEditorVisualizerGradient = null;
    clipEditorVisualizerGradientSize = "";
  }

  const context = clipEditorVisualizerContext;
  if (!context) return;
  context.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0);
  context.clearRect(0, 0, width, height);
  const gradientSize = `${pixelWidth}x${pixelHeight}`;
  if (!clipEditorVisualizerGradient || clipEditorVisualizerGradientSize !== gradientSize) {
    clipEditorVisualizerGradient = context.createLinearGradient(0, height, 0, 0);
    clipEditorVisualizerGradient.addColorStop(0, "#4e1a95");
    clipEditorVisualizerGradient.addColorStop(.72, "#bc5df8");
    clipEditorVisualizerGradient.addColorStop(1, "#7140d4");
    clipEditorVisualizerGradientSize = gradientSize;
  }

  const gap = 2;
  const barWidth = Math.max((width - gap * (CLIP_EDITOR_VISUALIZER_BAR_COUNT - 1)) / CLIP_EDITOR_VISUALIZER_BAR_COUNT, 2);
  context.beginPath();
  for (let index = 0; index < CLIP_EDITOR_VISUALIZER_BAR_COUNT; index += 1) {
    const level = Number.isFinite(levels[index]) ? levels[index] : 0;
    const percentage = live
      ? Math.max(5, Math.min(100, 7 + level * 93))
      : 10 + Math.round(Math.max(.04, Math.min(1, level)) * 86);
    const barHeight = height * percentage / 100;
    const x = index * (barWidth + gap);
    const top = height - barHeight;
    const radius = Math.min(barWidth / 2, barHeight / 2);
    context.moveTo(x, height);
    context.lineTo(x, top + radius);
    context.quadraticCurveTo(x, top, x + radius, top);
    context.lineTo(x + barWidth - radius, top);
    context.quadraticCurveTo(x + barWidth, top, x + barWidth, top + radius);
    context.lineTo(x + barWidth, height);
    context.closePath();
  }
  context.fillStyle = clipEditorVisualizerGradient;
  context.fill();
}

function renderClipEditorWaveform(levels = []) {
  const bars = clipEditorWaveBars(levels);
  $("#clipEditorWaveBars").innerHTML = bars;
  clipEditorVisualizerStaticLevels = sampledClipEditorVisualizerLevels(levels);
  if (clipEditorPreviewAudio.paused || clipEditorPreviewAudio.ended) {
    clipEditorVisualizerDisplayedLevels.set(clipEditorVisualizerStaticLevels);
    drawClipEditorStageVisualizer(clipEditorVisualizerStaticLevels);
  }
  updateClipEditorRange();
}

function waitForClipEditorVideoEvent(video, eventName, timeout = 4_000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error("Video frame loading timed out."));
    }, timeout);
    const cleanup = () => {
      clearTimeout(timer);
      video.removeEventListener(eventName, finished);
      video.removeEventListener("error", failed);
    };
    const finished = () => { cleanup(); resolve(); };
    const failed = () => { cleanup(); reject(new Error("Video frames could not be loaded.")); };
    video.addEventListener(eventName, finished, { once: true });
    video.addEventListener("error", failed, { once: true });
  });
}

async function loadClipEditorVideoFrames(track, count = 12) {
  const request = ++clipEditorVideoFrameRequest;
  const strip = $("#clipEditorVideoFrames");
  strip.innerHTML = "";
  if (!track?.fileUrl || !clipEditorTrackIsVideo(track)) return;
  if (track.filePath && typeof api.videoFrames === "function") {
    try {
      const frames = await api.videoFrames({
        filePath: track.filePath,
        duration: clipEditorDuration(track),
        count,
      });
      if (request !== clipEditorVideoFrameRequest || clipEditorTrack()?.id !== track.id) return;
      if (Array.isArray(frames) && frames.length) {
        strip.innerHTML = frames.map((source) => `<img src="${source}" alt="">`).join("");
        updateClipEditorRange();
        return;
      }
    } catch {
      // The browser fallback below still works for media sources that permit
      // pixel reads from the renderer's origin.
    }
  }
  const video = document.createElement("video");
  video.preload = "auto";
  video.muted = true;
  video.playsInline = true;
  video.src = track.fileUrl;
  try {
    if (video.readyState < 1) {
      video.load();
      await waitForClipEditorVideoEvent(video, "loadedmetadata");
    }
    const duration = Number.isFinite(video.duration) && video.duration > 0
      ? video.duration
      : clipEditorDuration(track);
    const frames = [];
    const canvas = document.createElement("canvas");
    canvas.width = 240;
    canvas.height = 135;
    const context = canvas.getContext("2d", { alpha: false });
    if (!context) return;
    for (let index = 0; index < count; index += 1) {
      if (request !== clipEditorVideoFrameRequest) return;
      const target = Math.min(Math.max(duration * (index + .5) / count, 0), Math.max(duration - .02, 0));
      if (Math.abs(video.currentTime - target) > .015) {
        video.currentTime = target;
        await waitForClipEditorVideoEvent(video, "seeked");
      }
      context.fillStyle = "#000";
      context.fillRect(0, 0, canvas.width, canvas.height);
      const scale = Math.max(canvas.width / Math.max(video.videoWidth, 1), canvas.height / Math.max(video.videoHeight, 1));
      const width = video.videoWidth * scale;
      const height = video.videoHeight * scale;
      context.drawImage(video, (canvas.width - width) / 2, (canvas.height - height) / 2, width, height);
      frames.push(canvas.toDataURL("image/jpeg", .72));
    }
    if (request !== clipEditorVideoFrameRequest || clipEditorTrack()?.id !== track.id) return;
    strip.innerHTML = frames.map((source) => `<img src="${source}" alt="">`).join("");
    updateClipEditorRange();
  } catch {
    if (request === clipEditorVideoFrameRequest) strip.innerHTML = "";
  } finally {
    video.removeAttribute("src");
    video.load();
  }
}

async function loadClipEditorWaveform(track) {
  const request = ++clipEditorWaveformRequest;
  if (!track?.fileUrl) return;
  try {
    const response = await fetch(track.fileUrl);
    if (!response.ok) throw new Error("Could not read audio bytes.");
    const bytes = await response.arrayBuffer();
    const AudioContextClass = window.AudioContext || window.webkitAudioContext;
    if (!AudioContextClass) throw new Error("Audio analysis is unavailable.");
    const context = new AudioContextClass();
    const buffer = await context.decodeAudioData(bytes.slice(0));
    const levels = Array.from({ length: 224 }, (_, index) => {
      const start = Math.floor(index / 224 * buffer.length);
      const end = Math.max(start + 1, Math.floor((index + 1) / 224 * buffer.length));
      let peak = 0;
      for (let channel = 0; channel < buffer.numberOfChannels; channel += 1) {
        const samples = buffer.getChannelData(channel);
        const stride = Math.max(1, Math.floor((end - start) / 96));
        for (let sample = start; sample < end; sample += stride) peak = Math.max(peak, Math.abs(samples[sample] || 0));
      }
      return Math.sqrt(peak);
    });
    await context.close().catch(() => {});
    if (request !== clipEditorWaveformRequest || clipEditorTrack()?.id !== track.id) return;
    const maximum = Math.max(...levels, .0001);
    renderClipEditorWaveform(levels.map((level) => Math.max(.035, level / maximum)));
  } catch {
    // The live analyser below still renders actual audio during playback when
    // a custom media protocol cannot be fetched by Web Audio.
  }
}

async function ensureClipEditorLiveVisualizer() {
  if (clipEditorAnalyser) {
    if (clipEditorAudioContext?.state === "suspended") await clipEditorAudioContext.resume();
    return true;
  }
  const AudioContextClass = window.AudioContext || window.webkitAudioContext;
  if (!AudioContextClass) return false;
  try {
    clipEditorAudioContext = new AudioContextClass();
    clipEditorAudioSource = clipEditorAudioContext.createMediaElementSource(clipEditorPreviewAudio);
    clipEditorAnalyser = clipEditorAudioContext.createAnalyser();
    clipEditorAnalyser.fftSize = 512;
    clipEditorAnalyser.smoothingTimeConstant = .72;
    clipEditorAnalyserData = new Uint8Array(clipEditorAnalyser.frequencyBinCount);
    clipEditorAudioSource.connect(clipEditorAnalyser);
    clipEditorAnalyser.connect(clipEditorAudioContext.destination);
    await clipEditorAudioContext.resume();
    return true;
  } catch {
    clipEditorAnalyser = null;
    clipEditorAnalyserData = null;
    return false;
  }
}

function animateClipEditorVisualizer() {
  if (clipEditorVisualizerFrame) cancelAnimationFrame(clipEditorVisualizerFrame);
  clipEditorVisualizerPreviousTimestamp = 0;
  const draw = (timestamp) => {
    if (clipEditorPreviewAudio.paused || clipEditorPreviewAudio.ended || !clipEditorAnalyser || !clipEditorAnalyserData) {
      clipEditorVisualizerFrame = 0;
      return;
    }
    clipEditorAnalyser.getByteFrequencyData(clipEditorAnalyserData);
    if (clipEditorVisualizerBinRanges?.dataLength !== clipEditorAnalyserData.length) {
      const usableBins = Math.max(1, Math.floor(clipEditorAnalyserData.length * .72));
      const lower = new Uint16Array(CLIP_EDITOR_VISUALIZER_BAR_COUNT);
      const upper = new Uint16Array(CLIP_EDITOR_VISUALIZER_BAR_COUNT);
      for (let index = 0; index < CLIP_EDITOR_VISUALIZER_BAR_COUNT; index += 1) {
        lower[index] = Math.floor(index / CLIP_EDITOR_VISUALIZER_BAR_COUNT * usableBins);
        upper[index] = Math.max(lower[index] + 1, Math.floor((index + 1) / CLIP_EDITOR_VISUALIZER_BAR_COUNT * usableBins));
      }
      clipEditorVisualizerBinRanges = { dataLength: clipEditorAnalyserData.length, lower, upper };
    }

    for (let index = 0; index < CLIP_EDITOR_VISUALIZER_BAR_COUNT; index += 1) {
      const low = clipEditorVisualizerBinRanges.lower[index];
      const high = clipEditorVisualizerBinRanges.upper[index];
      let energy = 0;
      for (let bin = low; bin < high; bin += 1) energy = Math.max(energy, clipEditorAnalyserData[bin]);
      clipEditorVisualizerTargetLevels[index] = energy / 255;
    }

    if (!clipEditorVisualizerPreviousTimestamp) {
      clipEditorVisualizerDisplayedLevels.set(clipEditorVisualizerTargetLevels);
    } else {
      const elapsed = Math.min(Math.max((timestamp - clipEditorVisualizerPreviousTimestamp) / 1000, 1 / 240), 1 / 15);
      for (let index = 0; index < CLIP_EDITOR_VISUALIZER_BAR_COUNT; index += 1) {
        const current = clipEditorVisualizerDisplayedLevels[index];
        const target = clipEditorVisualizerTargetLevels[index];
        const responseTime = target >= current ? .015 : .07;
        const blend = 1 - Math.exp(-elapsed / responseTime);
        clipEditorVisualizerDisplayedLevels[index] = current + (target - current) * blend;
      }
    }
    clipEditorVisualizerPreviousTimestamp = timestamp;
    drawClipEditorStageVisualizer(clipEditorVisualizerDisplayedLevels, { live: true });
    clipEditorVisualizerFrame = requestAnimationFrame(draw);
  };
  clipEditorVisualizerFrame = requestAnimationFrame(draw);
}

function renderClipEditorRuler(duration) {
  const ruler = $("#clipEditorRuler");
  const intervals = duration <= 30 ? 6 : duration <= 90 ? 6 : duration <= 300 ? 5 : 6;
  ruler.innerHTML = Array.from({ length: intervals + 1 }, (_, index) => {
    const seconds = Math.round(duration * index / intervals);
    return `<span style="left:${index / intervals * 100}%">${escapeHTML(formatTime(seconds))}</span>`;
  }).join("");
}

function parseClipEditorTime(value) {
  const parts = String(value || "").trim().split(":");
  if (!parts.length || parts.length > 3 || parts.some((part) => !/^\d+$/.test(part))) return null;
  const numbers = parts.map(Number);
  if (parts.length > 1 && numbers.at(-1) >= 60) return null;
  if (parts.length === 3 && numbers[1] >= 60) return null;
  if (parts.length === 1) return numbers[0];
  if (parts.length === 2) return numbers[0] * 60 + numbers[1];
  return numbers[0] * 3600 + numbers[1] * 60 + numbers[2];
}

function setClipEditorBoundary(boundary, seconds) {
  const track = clipEditorTrack();
  if (!track) return;
  const duration = clipEditorDuration(track);
  const value = Math.max(0, Math.min(Math.round(Number(seconds) || 0), duration));
  const previousStart = clipEditorStartSeconds;
  const previousEnd = clipEditorEndSeconds;
  if (boundary === "start") clipEditorStartSeconds = Math.min(value, clipEditorEndSeconds - 1);
  else clipEditorEndSeconds = Math.max(clipEditorStartSeconds + 1, value);
  if (previousStart !== clipEditorStartSeconds || previousEnd !== clipEditorEndSeconds) {
    void stopClipRangePreview({ unload: false });
  }
  updateClipEditorRange();
}

function commitClipEditorTime(boundary) {
  const input = $(`#clipEditor${boundary === "start" ? "Start" : "End"}Input`);
  const seconds = parseClipEditorTime(input.value);
  if (seconds === null) {
    input.setAttribute("aria-invalid", "true");
    input.value = formatTime(boundary === "start" ? clipEditorStartSeconds : clipEditorEndSeconds);
    return;
  }
  input.removeAttribute("aria-invalid");
  setClipEditorBoundary(boundary, seconds);
}

function clipEditorSecondsAtPointer(event) {
  const waveform = $("#clipEditorWaveform");
  const bounds = waveform.getBoundingClientRect();
  const ratio = Math.max(0, Math.min(1, (event.clientX - bounds.left) / bounds.width));
  return Math.round(ratio * clipEditorDuration());
}

function bindClipEditorHandle(boundary) {
  const handle = $(`#clipEditor${boundary === "start" ? "Start" : "End"}Handle`);
  let activePointerID = null;
  const finishDrag = (event) => {
    if (activePointerID !== event.pointerId) return;
    handle.classList.remove("dragging");
    if (handle.hasPointerCapture(event.pointerId)) handle.releasePointerCapture(event.pointerId);
    activePointerID = null;
  };
  handle.onpointerdown = (event) => {
    if (event.button !== 0) return;
    event.preventDefault();
    handle.focus();
    activePointerID = event.pointerId;
    handle.classList.add("dragging");
    handle.setPointerCapture(event.pointerId);
  };
  handle.onpointermove = (event) => {
    if (activePointerID !== event.pointerId) return;
    setClipEditorBoundary(boundary, clipEditorSecondsAtPointer(event));
  };
  handle.onpointerup = finishDrag;
  handle.onpointercancel = finishDrag;
  handle.onkeydown = (event) => {
    if (event.ctrlKey || event.altKey || event.metaKey) return;
    const duration = clipEditorDuration();
    const increment = event.shiftKey ? 5 : 1;
    let value = boundary === "start" ? clipEditorStartSeconds : clipEditorEndSeconds;
    if (event.key === "ArrowLeft") value -= increment;
    else if (event.key === "ArrowRight") value += increment;
    else if (event.key === "Home") value = boundary === "start" ? 0 : clipEditorStartSeconds + 1;
    else if (event.key === "End") value = boundary === "start" ? clipEditorEndSeconds - 1 : duration;
    else return;
    event.preventDefault();
    setClipEditorBoundary(boundary, value);
  };
}

function updateClipEditorRange() {
  const track = clipEditorTrack();
  if (!track) return;
  const duration = clipEditorDuration(track);
  const start = Math.max(0, Math.min(clipEditorStartSeconds, duration - 1));
  const end = Math.max(start + 1, Math.min(clipEditorEndSeconds, duration));
  clipEditorStartSeconds = start;
  clipEditorEndSeconds = end;
  $("#clipEditorStartInput").value = formatTime(start);
  $("#clipEditorEndInput").value = formatTime(end);
  $("#clipEditorLengthLabel").textContent = formatTime(end - start);
  const startRatio = start / duration;
  const endRatio = end / duration;
  const waveform = $("#clipEditorWaveform");
  waveform.style.setProperty("--clip-selection-start", `${startRatio * 100}%`);
  waveform.style.setProperty("--clip-selection-end", `${endRatio * 100}%`);
  waveform.style.setProperty("--clip-selection-width", `${(endRatio - startRatio) * 100}%`);
  renderClipEditorRuler(duration);
  const startHandle = $("#clipEditorStartHandle");
  const endHandle = $("#clipEditorEndHandle");
  startHandle.setAttribute("aria-valuemin", "0");
  startHandle.setAttribute("aria-valuemax", String(Math.max(0, end - 1)));
  startHandle.setAttribute("aria-valuenow", String(start));
  startHandle.setAttribute("aria-valuetext", formatTime(start));
  endHandle.setAttribute("aria-valuemin", String(Math.min(duration, start + 1)));
  endHandle.setAttribute("aria-valuemax", String(duration));
  endHandle.setAttribute("aria-valuenow", String(end));
  endHandle.setAttribute("aria-valuetext", formatTime(end));
  const bars = [...$("#clipEditorWaveBars").children];
  bars.forEach((bar, index) => {
    const position = (index + .5) / bars.length;
    bar.classList.toggle("selected", position >= startRatio && position <= endRatio);
  });
  [...$("#clipEditorVideoFrames").children].forEach((frame, index, frames) => {
    const position = (index + .5) / frames.length;
    frame.classList.toggle("selected", position >= startRatio && position <= endRatio);
  });
  clipEditorPreviewEndSeconds = end;
  syncClipRangePreviewTransport();
  syncClipEditorSaveButton();
}

function clipEditorHasUnsavedChanges() {
  return Math.abs(clipEditorStartSeconds - clipEditorSavedStartSeconds) > .001
    || Math.abs(clipEditorEndSeconds - clipEditorSavedEndSeconds) > .001;
}

function syncClipEditorSaveButton() {
  const button = $("#saveClipRange");
  const track = clipEditorTrack();
  button.disabled = !track || !clipEditorHasUnsavedChanges();
}

function renderClipEditorTrack({ resetRange = false } = {}) {
  const track = clipEditorTrack();
  const workspace = $("#clipEditorWorkspace");
  const empty = $("#clipEditorEmpty");
  workspace.hidden = !track;
  empty.hidden = Boolean(track);
  $("#previewClipRange").disabled = !track?.fileUrl;
  if (!track) {
    $("#clearClipRange").hidden = true;
    $("#clipEditorVideoFrame").hidden = true;
    $("#clipEditorVideoFrames").hidden = true;
    $("#clipEditorWaveBars").hidden = false;
    $("#clipEditorStatus").textContent = "Import or download a song before setting a clip range.";
    syncClipRangePreviewTransport();
    return;
  }
  const duration = clipEditorDuration(track);
  $("#clipEditorTrackTitle").textContent = track.title || "Unknown title";
  $("#clipEditorTrackMeta").textContent = `${track.artist || "Unknown Artist"} · ${displayAlbum(track)}`;
  $("#clipEditorTrackDuration").textContent = formatTime(duration);
  $("#clipEditorArtwork").innerHTML = track.artwork ? squareArtworkImageMarkup(track.artwork) : "♪";
  $(".clip-editor-settings-artwork").innerHTML = track.artwork ? squareArtworkImageMarkup(track.artwork) : "♪";
  renderClipEditorWaveform();
  const isVideo = clipEditorTrackIsVideo(track);
  $("#clipEditorVideoFrame").hidden = !isVideo;
  $("#clipEditorAudioStage").hidden = isVideo;
  $("#clipEditorVideoFrames").hidden = !isVideo;
  $("#clipEditorWaveBars").hidden = isVideo;
  if (isVideo) {
    clipEditorWaveformRequest += 1;
    void loadClipEditorVideoFrames(track);
  } else {
    clipEditorVideoFrameRequest += 1;
    void loadClipEditorWaveform(track);
  }
  clipEditorPreviewAudio.poster = track.artwork || "";
  if (track.artwork) {
    const trackID = track.id;
    void squareArtworkSource(track.artwork).then((cropped) => {
      if (clipEditorTrack()?.id === trackID) clipEditorPreviewAudio.poster = cropped;
    });
  }
  if (resetRange) {
    const savedRange = playbackRangeForTrack(state, track);
    const defaultStart = duration > 60 ? 15 : 0;
    clipEditorStartSeconds = savedRange?.startSeconds ?? defaultStart;
    clipEditorEndSeconds = savedRange?.endSeconds ?? Math.min(duration, defaultStart + 45);
    clipEditorSavedStartSeconds = savedRange?.startSeconds ?? 0;
    clipEditorSavedEndSeconds = savedRange?.endSeconds ?? duration;
  }
  updateClipEditorRange();
  const savedRange = playbackRangeForTrack(state, track);
  $("#clearClipRange").hidden = !savedRange;
  $("#clipEditorStatus").textContent = savedRange
    ? `This profile plays ${formatTime(savedRange.startSeconds)}–${formatTime(savedRange.endSeconds)}. The song file is unchanged.`
    : "Choose a range. The song file is never changed.";
  void prepareClipRangePreviewMedia(track, { seekToStart: true }).catch(() => {
    $("#clipEditorStatus").textContent = "Resonance could not load this song for preview.";
  });
}

function syncClipRangePreviewButton() {
  const button = $("#previewClipRange");
  const playing = !clipEditorPreviewAudio.paused && !clipEditorPreviewAudio.ended;
  button.classList.toggle("playing", playing);
  $("#clipEditorStageVisualizer").classList.toggle("playing", playing);
  if (playing) animateClipEditorVisualizer();
  else if (clipEditorVisualizerFrame) {
    cancelAnimationFrame(clipEditorVisualizerFrame);
    clipEditorVisualizerFrame = 0;
  }
  if (!playing) {
    clipEditorVisualizerPreviousTimestamp = 0;
    clipEditorVisualizerDisplayedLevels.set(clipEditorVisualizerStaticLevels);
    drawClipEditorStageVisualizer(clipEditorVisualizerStaticLevels);
  }
  button.setAttribute("aria-pressed", String(playing));
  button.setAttribute("aria-label", playing ? "Pause preview" : "Play preview");
  button.disabled = clipEditorPreviewLoading || !clipEditorTrack()?.fileUrl;
  button.innerHTML = clipEditorPreviewLoading
    ? '<span>Preparing…</span>'
    : playing
    ? '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="7" y="5" width="3.5" height="14" rx="1"></rect><rect x="13.5" y="5" width="3.5" height="14" rx="1"></rect></svg><span>Pause</span>'
    : '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5v14l11-7z"></path></svg><span>Preview</span>';
}

function syncClipRangePreviewTransport() {
  const seek = $("#clipEditorPreviewSeek");
  const track = clipEditorTrack();
  const start = clipEditorStartSeconds;
  const end = Math.max(start + .25, clipEditorEndSeconds);
  const rawPosition = Number(clipEditorPreviewAudio.currentTime);
  const position = Math.min(Math.max(Number.isFinite(rawPosition) && rawPosition > 0 ? rawPosition : start, start), end);
  seek.min = String(start);
  seek.max = String(end);
  seek.step = "0.01";
  seek.value = String(position);
  seek.disabled = clipEditorPreviewLoading || !track?.fileUrl;
  seek.setAttribute("aria-valuetext", `${formatTime(position)} of ${formatTime(end)}`);
  $("#clipEditorPreviewCurrent").textContent = formatTime(position);
  $("#clipEditorPreviewEnd").textContent = formatTime(end);
  const duration = clipEditorDuration(track);
  $("#clipEditorWaveform").style.setProperty("--clip-playhead", `${Math.max(0, Math.min(1, position / duration)) * 100}%`);
}

function waitForClipRangePreviewMetadata() {
  if (clipEditorPreviewAudio.readyState >= 1) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const cleanup = () => {
      clipEditorPreviewAudio.removeEventListener("loadedmetadata", loaded);
      clipEditorPreviewAudio.removeEventListener("error", failed);
    };
    const loaded = () => { cleanup(); resolve(); };
    const failed = () => { cleanup(); reject(new Error("Resonance could not load this song for preview.")); };
    clipEditorPreviewAudio.addEventListener("loadedmetadata", loaded, { once: true });
    clipEditorPreviewAudio.addEventListener("error", failed, { once: true });
    clipEditorPreviewAudio.load();
  });
}

async function prepareClipRangePreviewMedia(track = clipEditorTrack(), { seekToStart = false } = {}) {
  if (!track?.fileUrl) {
    syncClipRangePreviewButton();
    syncClipRangePreviewTransport();
    return false;
  }
  if (clipEditorPreviewAudio.getAttribute("src") !== track.fileUrl) {
    clipEditorPreviewAudio.pause();
    clipEditorPreviewAudio.src = track.fileUrl;
    clipEditorPreviewAudio.volume = playbackGainForVolume(state.volume);
    await waitForClipRangePreviewMetadata();
  }
  clipEditorPreviewEndSeconds = clipEditorEndSeconds;
  if (seekToStart || clipEditorPreviewAudio.currentTime < clipEditorStartSeconds || clipEditorPreviewAudio.currentTime >= clipEditorEndSeconds) {
    clipEditorPreviewAudio.currentTime = clipEditorStartSeconds;
  }
  syncClipRangePreviewButton();
  syncClipRangePreviewTransport();
  return true;
}

async function resumePlaybackAfterClipRangePreview() {
  if (!clipEditorPreviewInterruptedPlayback) return;
  clipEditorPreviewInterruptedPlayback = false;
  if (currentTrack() && audio.paused) await requestPlayback();
}

async function stopClipRangePreview({ resumeMain = true, unload = true } = {}) {
  const wasActive = clipEditorPreviewLoading || Boolean(clipEditorPreviewAudio.getAttribute("src"));
  clipEditorPreviewRequest += 1;
  clipEditorPreviewLoading = false;
  clipEditorPreviewAudio.pause();
  if (unload) {
    clipEditorPreviewAudio.removeAttribute("src");
    clipEditorPreviewAudio.load();
    clipEditorPreviewEndSeconds = 0;
  } else {
    clipEditorPreviewEndSeconds = clipEditorEndSeconds;
    if (clipEditorPreviewAudio.readyState >= 1) clipEditorPreviewAudio.currentTime = clipEditorStartSeconds;
  }
  syncClipRangePreviewButton();
  syncClipRangePreviewTransport();
  if (wasActive && $("#clipEditorDialog").open) {
    $("#clipEditorStatus").textContent = "Preview stopped. This does not save the range.";
  }
  if (resumeMain) await resumePlaybackAfterClipRangePreview();
  else clipEditorPreviewInterruptedPlayback = false;
}

async function toggleClipRangePreview() {
  if (!clipEditorPreviewAudio.paused) {
    clipEditorPreviewAudio.pause();
    syncClipRangePreviewButton();
    syncClipRangePreviewTransport();
    await resumePlaybackAfterClipRangePreview();
    return;
  }
  const track = clipEditorTrack();
  if (!track?.fileUrl) return;
  void ensureClipEditorLiveVisualizer();
  const request = ++clipEditorPreviewRequest;
  clipEditorPreviewLoading = true;
  syncClipRangePreviewButton();
  if (!audio.paused) {
    clipEditorPreviewInterruptedPlayback = true;
    audio.pause();
  }
  const status = $("#clipEditorStatus");
  try {
    await prepareClipRangePreviewMedia(track);
    if (request !== clipEditorPreviewRequest) return;
    if (clipEditorPreviewAudio.currentTime >= clipEditorEndSeconds - .02) {
      clipEditorPreviewAudio.currentTime = clipEditorStartSeconds;
    }
    clipEditorPreviewEndSeconds = clipEditorEndSeconds;
    await clipEditorPreviewAudio.play();
    status.textContent = `Previewing ${formatTime(clipEditorStartSeconds)}–${formatTime(clipEditorEndSeconds)}. This does not save the range.`;
  } catch (error) {
    if (request !== clipEditorPreviewRequest) return;
    await stopClipRangePreview();
    status.textContent = error?.message || "Resonance could not preview this clip range.";
  } finally {
    if (request === clipEditorPreviewRequest) {
      clipEditorPreviewLoading = false;
      syncClipRangePreviewButton();
      syncClipRangePreviewTransport();
    }
  }
}

async function stepClipEditorTrack(direction) {
  const tracks = tracksForActiveProfile(state);
  if (!tracks.length) return;
  const currentIndex = Math.max(0, tracks.findIndex((track) => track.id === clipEditorTrack()?.id));
  const nextIndex = (currentIndex + direction + tracks.length) % tracks.length;
  await stopClipRangePreview();
  setCustomSelectValue($("#clipEditorTrack"), tracks[nextIndex].id);
  renderClipEditorTrack({ resetRange: true });
}

function handleClipEditorKeybind(action) {
  if (!$("#clipEditorDialog").open) return false;
  if (action === "togglePlayback") void toggleClipRangePreview();
  else if (action === "previousTrack") void stepClipEditorTrack(-1);
  else if (action === "nextTrack") void stepClipEditorTrack(1);
  else if (action === "volumeDown") {
    setPlaybackVolume(state.volume - .05);
    clipEditorPreviewAudio.volume = playbackGainForVolume(state.volume);
  } else if (action === "volumeUp") {
    setPlaybackVolume(state.volume + .05);
    clipEditorPreviewAudio.volume = playbackGainForVolume(state.volume);
  } else return false;
  return true;
}

function openClipEditor() {
  closeProfileMenu();
  const select = $("#clipEditorTrack");
  const visibleTracks = tracksForActiveProfile(state);
  const preferredTrack = visibleTracks.find((track) => track.id === currentID) || visibleTracks[0];
  setCustomSelectOptions(select, visibleTracks.map((track) => ({
    value: track.id,
    label: `${track.title} — ${track.artist || "Unknown Artist"}`,
    triggerLabel: track.title || "Unknown title",
  })), preferredTrack?.id);
  renderClipEditorTrack({ resetRange: true });
  $("#clipEditorSettings").hidden = true;
  $("#clipEditorHelp").hidden = true;
  $("#clipEditorSettingsButton").setAttribute("aria-expanded", "false");
  $("#clipEditorHelpButton").setAttribute("aria-expanded", "false");
  $("#clipEditorDialog").classList.remove("preview-expanded");
  $("#clipEditorExpand").setAttribute("aria-pressed", "false");
  $("#clipEditorDialog").showModal();
  requestAnimationFrame(() => {
    drawClipEditorStageVisualizer(clipEditorVisualizerStaticLevels);
    (preferredTrack ? $("#previewClipRange") : $("#saveClipRange"))?.focus();
  });
}

async function saveClipRange() {
  const track = clipEditorTrack();
  if (!track) return;
  await stopClipRangePreview();
  const button = $("#saveClipRange");
  const status = $("#clipEditorStatus");
  button.disabled = true;
  button.textContent = "Saving…";
  try {
    const duration = clipEditorDuration(track);
    const usesFullSong = clipEditorStartSeconds <= .001 && clipEditorEndSeconds >= duration - .001;
    const range = usesFullSong
      ? (removeClipRangeForTrack(state, track), { startSeconds: 0, endSeconds: duration })
      : setClipRangeForTrack(state, track, clipEditorStartSeconds, clipEditorEndSeconds);
    if (!range) throw new Error("Choose a valid playback range.");
    clipRangeMutationGeneration += 1;
    if (currentID === track.id && (audio.currentTime < range.startSeconds || audio.currentTime >= range.endSeconds)) {
      audio.currentTime = range.startSeconds;
      state.position = range.startSeconds;
    }
    await persist();
    if (track.remoteID) schedulePlaylistSync();
    clipEditorSavedStartSeconds = range.startSeconds;
    clipEditorSavedEndSeconds = range.endSeconds;
    $("#clearClipRange").hidden = usesFullSong;
    const profileName = state.syncProfiles.find((profile) => profile.id === activeProfileID())?.name || activeProfileID();
    status.textContent = track.remoteID
      ? `Saved for ${profileName}. Syncing this range to the server…`
      : `Saved for ${profileName} on this device. Upload the song to sync its range.`;
    showNotice(usesFullSong
      ? `“${track.title}” now plays in full.`
      : `Playback for “${track.title}” is now limited to ${formatTime(range.startSeconds)}–${formatTime(range.endSeconds)}.`, "status");
    syncClipEditorSaveButton();
  } catch (error) {
    status.textContent = error.message || "Resonance could not save this clip range.";
  } finally {
    button.textContent = "Save";
    syncClipEditorSaveButton();
  }
}

async function seekClipEditorPreview(seconds) {
  const track = clipEditorTrack();
  if (!track?.fileUrl) return;
  try {
    await prepareClipRangePreviewMedia(track);
    clipEditorPreviewAudio.currentTime = Math.max(clipEditorStartSeconds, Math.min(seconds, clipEditorEndSeconds));
    syncClipRangePreviewTransport();
  } catch (error) {
    $("#clipEditorStatus").textContent = error?.message || "Resonance could not seek this clip.";
  }
}

function toggleClipEditorPopover(name) {
  const settings = $("#clipEditorSettings");
  const help = $("#clipEditorHelp");
  const openSettings = name === "settings" && settings.hidden;
  const openHelp = name === "help" && help.hidden;
  settings.hidden = !openSettings;
  help.hidden = !openHelp;
  $("#clipEditorSettingsButton").setAttribute("aria-expanded", String(openSettings));
  $("#clipEditorHelpButton").setAttribute("aria-expanded", String(openHelp));
  if (openSettings) requestAnimationFrame(() => $("#clipEditorStartInput").focus());
  if (openHelp) requestAnimationFrame(() => $("#closeClipEditorHelp").focus());
}

async function clearClipRange() {
  const track = clipEditorTrack();
  if (!track) return;
  await stopClipRangePreview();
  clipEditorStartSeconds = 0;
  clipEditorEndSeconds = clipEditorDuration(track);
  renderClipEditorTrack();
  $("#clipEditorStatus").textContent = "Full-song playback is selected. Press Save to apply it.";
}

function listeningHistoryMetric(icon, tone, value, suffix, label) {
  return `<div class="history-metric">
    <span class="history-metric-icon ${tone}" aria-hidden="true">${icon}</span>
    <span><strong title="${escapeHTML(value)}">${escapeHTML(value)}${suffix ? `<small>${escapeHTML(suffix)}</small>` : ""}</strong><em>${escapeHTML(label)}</em></span>
  </div>`;
}

function historyDateLabel(date, options = {}) {
  return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", ...options }).format(date);
}

function historyBucketLabel(summary, date, options = {}) {
  const hourlyOptions = summary.granularity === "hour" ? { hour: "numeric" } : {};
  return historyDateLabel(date, { ...hourlyOptions, ...options });
}

function historyListenedTime(seconds) {
  const value = Math.max(0, Number(seconds) || 0);
  if (value > 0 && value < 60) return `${Math.max(1, Math.round(value))} sec`;
  return `${Math.round(value / 60).toLocaleString()} min`;
}

function historyAxisLabel(value) {
  const absolute = Math.abs(value);
  if (absolute === 0) return "0m";
  if (absolute >= 60) {
    const hours = value / 60;
    const precision = Math.abs(hours) >= 10 ? 0 : 1;
    return `${Number(hours.toFixed(precision)).toLocaleString()}h`;
  }
  if (absolute >= 10) return `${Math.round(value).toLocaleString()}m`;
  const precision = absolute >= 1 ? 1 : 2;
  return `${Number(value.toFixed(precision)).toLocaleString()}m`;
}

function historyDayDetailsMarkup(summary, dayKey) {
  const dayIndex = summary.days.findIndex((day) => day.key === dayKey);
  if (dayIndex < 0) return "";
  const day = summary.days[dayIndex];
  const activeTracks = tracksForActiveProfile(state);
  const songs = summary.songSeries
    .map((series) => {
      const activity = series.days[dayIndex];
      const track = activeTracks.find((item) => item.id === series.trackID)
        || activeTracks.find((item) => series.remoteID && item.remoteID === series.remoteID)
        || series;
      return { activity, track, trackID: series.trackID };
    })
    .filter((item) => item.activity.seconds > 0 || item.activity.plays > 0)
    .sort((left, right) => right.activity.seconds - left.activity.seconds || right.activity.plays - left.activity.plays);
  const hourly = summary.granularity === "hour";
  const date = new Intl.DateTimeFormat(undefined, {
    weekday: "long",
    month: "long",
    day: "numeric",
    year: "numeric",
    ...(hourly ? { hour: "numeric" } : {}),
  }).format(day.date);
  const songRows = songs.map(({ activity, track, trackID }, index) => {
    const title = track?.title || "Unknown song";
    const artist = track?.artist || "Unknown artist";
    const album = displayAlbum(track);
    return `<div class="history-day-song" role="row" data-history-track="${escapeHTML(trackID)}" tabindex="0" aria-keyshortcuts="Shift+F10">
      <span class="history-day-song-number" role="cell">${index + 1}</span>
      <span role="cell">${artwork(track)}</span>
      <span class="history-day-song-copy" role="cell"><strong>${escapeHTML(title)}</strong><small>${escapeHTML(artist)} / Audio</small></span>
      <span class="history-day-song-album" role="cell">${escapeHTML(album)}</span>
      <span class="history-day-song-time" role="cell">${escapeHTML(historyListenedTime(activity.seconds))}</span>
      <span class="history-day-song-plays" role="cell">${activity.plays.toLocaleString()}</span>
    </div>`;
  }).join("");
  return `<header class="history-day-details-header">
    <div><span class="eyebrow">${hourly ? "HOUR" : "DAY"} BREAKDOWN</span><h3>${escapeHTML(date)}</h3></div>
    <div class="history-day-details-totals">
      <span><strong>${escapeHTML(historyListenedTime(day.seconds))}</strong><small>Listening time</small></span>
      <span><strong>${day.plays.toLocaleString()}</strong><small>${day.plays === 1 ? "Play" : "Plays"}</small></span>
      <span><strong>${songs.length.toLocaleString()}</strong><small>${songs.length === 1 ? "Song" : "Songs"}</small></span>
      <button id="closeHistoryDayDetails" type="button" title="Collapse day details" aria-label="Collapse day details"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m6 15 6-6 6 6"/></svg></button>
    </div>
      </header>
  <div class="history-day-song-list" role="table" tabindex="0" aria-label="Songs played ${hourly ? "during" : "on"} ${escapeHTML(date)}">
    <div class="history-day-song-header" role="row">
      <span role="columnheader">#</span>
      <span role="columnheader"></span>
      <span role="columnheader">Title</span>
      <span role="columnheader">Album</span>
      <span role="columnheader">Listening time</span>
      <span role="columnheader">Plays</span>
    </div>
    ${songRows || `<div class="history-day-empty">No song activity was recorded for this ${hourly ? "hour" : "day"}.</div>`}
  </div>`;
}

function historyChartMarkup(summary) {
  const width = 732;
  const height = 250;
  const left = 8;
  const right = 40;
  const top = 8;
  const bottom = 28;
  const plotWidth = width - left - right;
  const plotHeight = height - top - bottom;
  const peak = Math.max(0, ...summary.days.map((day) => day.seconds / 60));
  const axisMaximum = summary.granularity === "hour" ? 60 : niceChartMaximum(peak);
  const points = summary.days.map((day, index) => ({
    x: left + (index + 0.5) / summary.days.length * plotWidth,
    y: top + plotHeight - (Math.min(day.seconds / 60, axisMaximum) / axisMaximum * plotHeight),
    day,
  }));
  const highlight = points.reduce((best, point) => point.day.seconds > best.day.seconds ? point : best, points.at(-1));
  const yTicks = Array.from({ length: 5 }, (_, index) => axisMaximum * (1 - index / 4));
  const grid = yTicks.map((value) => {
    const y = top + plotHeight - (value / axisMaximum * plotHeight);
    return `<line x1="${left}" y1="${y}" x2="${width - right}" y2="${y}"/>`;
  }).join("");
  const yAxis = yTicks.map((value) => {
    const y = top + plotHeight - (value / axisMaximum * plotHeight);
    return `<text x="10" y="${y + 4}" text-anchor="start">${historyAxisLabel(value)}</text>`;
  }).join("");
  const xTickInterval = Math.max(1, Math.ceil(summary.days.length / 6));
  const xAxis = points.filter((point, index) => index % xTickInterval === 0 || index === points.length - 1).map((point) =>
    `<text x="${point.x.toFixed(2)}" y="${height - 5}" text-anchor="middle">${escapeHTML(historyBucketLabel(summary, point.day.date))}</text>`).join("");
  const barDensity = Math.max(0.28, Math.min(0.72, 0.78 - summary.days.length / 180));
  const barWidth = Math.max(5, Math.min(38, plotWidth / summary.days.length * barDensity));
  const bars = points.map((point, index) => {
    const barHeight = Math.max(0, top + plotHeight - point.y);
    const peakClass = peak > 0 && point === highlight ? " peak" : "";
    const selectedClass = point.day.key === selectedListeningHistoryDayKey ? " selected" : "";
    const label = `${historyBucketLabel(summary, point.day.date)}: ${historyListenedTime(point.day.seconds)}, ${point.day.plays} ${point.day.plays === 1 ? "play" : "plays"}`;
    return `<rect class="history-bar${peakClass}${selectedClass}" x="${(point.x - barWidth / 2).toFixed(2)}" y="${point.y.toFixed(2)}" width="${barWidth.toFixed(2)}" height="${barHeight.toFixed(2)}" rx="${Math.min(5, barWidth / 2).toFixed(2)}" data-history-day="${escapeHTML(point.day.key)}" data-history-day-index="${index}" role="button" tabindex="0" aria-label="${escapeHTML(label)}"><title>${escapeHTML(label)}</title></rect>`;
  }).join("");
  const periodDescription = summary.granularity === "hour"
    ? `${summary.days.length} hours of hourly`
    : `${summary.days.length} days of daily`;
  return `<div class="history-chart-frame"><div class="history-chart-viewport" data-day-count="${summary.days.length}"><svg class="history-chart-svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" preserveAspectRatio="none" data-plot-left="${left}" data-plot-right="${right}" data-plot-top="${top}" data-plot-bottom="${bottom}" data-axis-maximum="${axisMaximum}" role="img" aria-label="${periodDescription} listening minutes">
    <defs>
      <linearGradient id="historyBarGradient" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#9b7aff"/><stop offset="1" stop-color="#5d35d8"/></linearGradient>
      <linearGradient id="historyPeakBarGradient" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ff806c"/><stop offset="1" stop-color="#8a42eb"/></linearGradient>
    </defs>
    <g class="history-grid">${grid}</g>
    ${bars}
    <g class="history-x-axis">${xAxis}</g>
    <line class="history-hover-guide" x1="0" y1="${top}" x2="0" y2="${top + plotHeight}" hidden/>
  </svg>${peak ? "" : '<p class="history-empty-chart">Play something and your activity will appear here.</p>'}</div><svg class="history-y-axis" width="52" height="${height}" viewBox="0 0 52 ${height}" aria-hidden="true"><g>${yAxis}</g></svg><div class="history-chart-tooltip" role="tooltip" hidden></div></div>`;
}

function bindListeningHistoryChartInteractions(summary) {
  const frame = $("#listeningHistoryChart .history-chart-frame");
  const viewport = frame?.querySelector(".history-chart-viewport");
  const svg = viewport?.querySelector(".history-chart-svg");
  const guide = svg?.querySelector(".history-hover-guide");
  const tooltip = frame?.querySelector(".history-chart-tooltip");
  if (!frame || !viewport || !svg || !guide || !tooltip) return;
  const hide = () => {
    guide.hidden = true;
    tooltip.hidden = true;
  };
  const expandDay = (bar) => {
    if (!bar?.dataset.historyDay) return;
    selectedListeningHistoryDayKey = bar.dataset.historyDay;
    renderListeningHistory();
    requestAnimationFrame(() => $("#closeHistoryDayDetails")?.focus());
  };
  viewport.addEventListener("pointermove", (event) => {
    const rectangle = svg.getBoundingClientRect();
    const viewWidth = svg.viewBox.baseVal.width;
    const viewHeight = svg.viewBox.baseVal.height;
    const plotLeft = Number(svg.dataset.plotLeft);
    const plotRight = Number(svg.dataset.plotRight);
    const plotTop = Number(svg.dataset.plotTop);
    const plotBottom = Number(svg.dataset.plotBottom);
    const plotWidth = viewWidth - plotLeft - plotRight;
    const plotHeight = viewHeight - plotTop - plotBottom;
    const svgX = (event.clientX - rectangle.left) / rectangle.width * viewWidth;
    const svgY = (event.clientY - rectangle.top) / rectangle.height * viewHeight;
    if (svgX < plotLeft || svgX > viewWidth - plotRight || svgY < plotTop || svgY > plotTop + plotHeight) {
      hide();
      return;
    }
    const dayProgress = (svgX - plotLeft) / plotWidth;
    const dayIndex = Math.max(0, Math.min(
      summary.days.length - 1,
      Math.floor(dayProgress * summary.days.length),
    ));
    const day = summary.days[dayIndex];
    const guideX = plotLeft + (dayIndex + 0.5) / summary.days.length * plotWidth;
    guide.setAttribute("x1", String(guideX));
    guide.setAttribute("x2", String(guideX));
    guide.hidden = false;
    const date = historyBucketLabel(summary, day.date, { weekday: "long" });
    const activeSeries = summary.songSeries
      .map((series) => ({ series, day: series.days[dayIndex] }))
      .filter((item) => item.day.seconds > 0 || item.day.plays > 0);
    const top = activeSeries.sort((left, right) => right.day.seconds - left.day.seconds)[0];
    const activeTracks = tracksForActiveProfile(state);
    const topTrack = top && (activeTracks.find((track) => track.id === top.series.trackID)
      || activeTracks.find((track) => top.series.remoteID && track.remoteID === top.series.remoteID)
      || top.series);
    tooltip.innerHTML = `<span class="history-tooltip-date">${escapeHTML(date)}</span>
      <span><b>${Math.round(day.seconds / 60).toLocaleString()} min</b><small>${day.plays.toLocaleString()} ${day.plays === 1 ? "play" : "plays"}</small></span>
      <em>${topTrack ? `Top song: ${escapeHTML(topTrack.title)}` : "No listening recorded"}</em>`;
    tooltip.hidden = false;
    const frameRectangle = frame.getBoundingClientRect();
    const pointerX = event.clientX - frameRectangle.left;
    const pointerY = event.clientY - frameRectangle.top;
    const maximumLeft = Math.max(8, frameRectangle.width - tooltip.offsetWidth - 8);
    tooltip.style.left = `${Math.max(8, Math.min(maximumLeft, pointerX + 14))}px`;
    const above = pointerY - tooltip.offsetHeight - 14;
    tooltip.style.top = `${above >= 8 ? above : Math.max(8, Math.min(frameRectangle.height - tooltip.offsetHeight - 8, pointerY + 14))}px`;
  });
  viewport.addEventListener("pointerleave", hide);
  viewport.addEventListener("click", (event) => expandDay(event.target.closest(".history-bar")));
  viewport.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" && event.key !== " ") return;
    const bar = event.target.closest(".history-bar");
    if (!bar) return;
    event.preventDefault();
    expandDay(bar);
  });
}

function currentListeningHistorySummary() {
  const range = Number($("#listeningHistoryRange").value) || 30;
  return summarizeListeningHistory(state, range, new Date(), listeningHistoryWindowOffset);
}

function preferredListeningHistoryBucket(summary, now = new Date()) {
  return summary.days.findLast((day) => day.date.getTime() <= now.getTime()) || summary.days.at(-1) || null;
}

function ensureListeningHistorySelection(summary = currentListeningHistorySummary()) {
  const selectionExists = summary.days.some((day) => day.key === selectedListeningHistoryDayKey);
  if (!selectionExists) selectedListeningHistoryDayKey = preferredListeningHistoryBucket(summary)?.key || null;
}

function shiftListeningHistoryWindow(offsetChange) {
  const currentSummary = currentListeningHistorySummary();
  const selectedIndex = currentSummary.days.findIndex((day) => day.key === selectedListeningHistoryDayKey);
  listeningHistoryWindowOffset = Math.max(0, listeningHistoryWindowOffset + offsetChange);
  const nextSummary = currentListeningHistorySummary();
  selectedListeningHistoryDayKey = selectedIndex >= 0
    ? nextSummary.days[Math.min(selectedIndex, nextSummary.days.length - 1)]?.key || null
    : preferredListeningHistoryBucket(nextSummary)?.key || null;
  renderListeningHistory();
}

function renderListeningHistory() {
  const range = Number($("#listeningHistoryRange").value) || 30;
  const summary = currentListeningHistorySummary();
  const allTimeStats = summarizeListeningStats(state, new Date());
  const activeTracks = tracksForActiveProfile(state);
  const topSong = allTimeStats.songRanking[0];
  const topTrack = activeTracks.find((track) => track.id === allTimeStats.topTrackID)
    || activeTracks.find((track) => topSong?.remoteID && track.remoteID === topSong.remoteID)
    || topSong;
  const rankedSongs = allTimeStats.songRanking.map((song, index) => {
    const track = activeTracks.find((item) => item.id === song.trackID)
      || activeTracks.find((item) => song.remoteID && item.remoteID === song.remoteID)
      || song;
    const title = track.title || "Unknown song";
    const artist = track.artist || "Unknown artist";
    return `<article class="history-ranked-song" data-history-track="${escapeHTML(song.trackID)}" tabindex="0" aria-keyshortcuts="Shift+F10">
      <span class="history-ranked-position">#${index + 1}</span>
      ${artwork(track)}
      <strong title="${escapeHTML(title)}">${escapeHTML(title)}</strong>
      <small title="${escapeHTML(artist)}">${escapeHTML(artist)}</small>
      <em>${escapeHTML(historyListenedTime(song.seconds))} · ${song.plays.toLocaleString()} ${song.plays === 1 ? "play" : "plays"}</em>
    </article>`;
  }).join("");
  const topSongTitle = topTrack?.title || (allTimeStats.topTrackID ? "Unknown song" : "No listening yet");
  const topSongArtist = topTrack?.artist || (allTimeStats.topTrackID ? "Unknown artist" : "Play a song to build your ranking");
  const dialog = $("#listeningHistoryDialog");
  const previousDialogScroll = dialog.classList.contains("day-expanded") ? dialog.scrollTop : 0;
  const stats = $("#listeningHistoryStats");
  const chartSection = $("#listeningHistoryChartSection");
  const statsMode = listeningHistoryMode === "stats";
  const toolbar = $("#listeningHistoryToolbar");
  const previousWindow = $("#historyPreviousWindow");
  const nextWindow = $("#historyNextWindow");
  $("#historyWindowLabel").textContent = formatHistoryWindowLabel(summary);
  const windowName = range === 1 ? "day" : `${range} days`;
  previousWindow.title = `Show previous ${windowName}`;
  previousWindow.setAttribute("aria-label", previousWindow.title);
  nextWindow.title = listeningHistoryWindowOffset === 1 && range === 1
    ? "Show today"
    : `Show next ${windowName}`;
  nextWindow.setAttribute("aria-label", nextWindow.title);
  nextWindow.disabled = listeningHistoryWindowOffset === 0;
  toolbar.hidden = statsMode;
  stats.innerHTML = `<div class="history-stats-summary">
    ${listeningHistoryMetric(historyClockIcon, "purple", historyListenedTime(allTimeStats.totalSeconds), "", "Total Time Listened")}
    ${listeningHistoryMetric(historyPlaysIcon, "coral", allTimeStats.plays.toLocaleString(), "", "Total Plays")}
    ${listeningHistoryMetric(historyTodayIcon, "violet", allTimeStats.songs.toLocaleString(), "", "Total Songs Heard")}
    ${listeningHistoryMetric(historyTodayIcon, "violet", allTimeStats.topArtist, "", "Most Popular Artist")}
  </div>
  <section class="history-top-song-section" aria-labelledby="historyTopSongTitle">
    <div class="history-top-song-feature">
      <button id="historyTopSongToggle" class="history-top-song-cover" type="button" aria-label="${listeningHistorySongsExpanded ? "Hide" : "Show"} songs ranked by listening time" aria-controls="historySongRanking" aria-expanded="${listeningHistorySongsExpanded}" ${rankedSongs ? "" : "disabled"}>
        ${artwork(topTrack)}
        <span class="history-top-song-expand" aria-hidden="true">›</span>
      </button>
      <div class="history-top-song-copy">
        <span class="eyebrow">MOST LISTENED SONG</span>
        <h3 id="historyTopSongTitle">${escapeHTML(topSongTitle)}</h3>
        <p>${escapeHTML(topSongArtist)}${allTimeStats.songRanking[0] ? ` · ${escapeHTML(historyListenedTime(allTimeStats.songRanking[0].seconds))}` : ""}</p>
        <small>${rankedSongs ? "Click the cover to view every song from most to least listened." : "Your song ranking will appear here."}</small>
      </div>
    </div>
    <div id="historySongRanking" class="history-song-ranking" aria-label="Songs ranked by listening time" ${listeningHistorySongsExpanded ? "" : "hidden"}>${rankedSongs}</div>
  </section>`;
  const topSongToggle = $("#historyTopSongToggle");
  if (topSongToggle) topSongToggle.onclick = () => {
    listeningHistorySongsExpanded = !listeningHistorySongsExpanded;
    renderListeningHistory();
    requestAnimationFrame(() => $("#historyTopSongToggle")?.focus());
  };
  stats.hidden = !statsMode;
  chartSection.hidden = statsMode;
  document.querySelectorAll("[data-history-mode]").forEach((button) => {
    const selected = button.dataset.historyMode === listeningHistoryMode;
    button.classList.toggle("active", selected);
    button.setAttribute("aria-pressed", String(selected));
  });
  if (statsMode) {
    $("#listeningHistoryChart").innerHTML = "";
  } else {
    $("#listeningHistoryChart").innerHTML = historyChartMarkup(summary);
    bindListeningHistoryChartInteractions(summary);
  }
  const details = $("#listeningHistoryDayDetails");
  const selectedBucketExists = summary.days.some((day) => day.key === selectedListeningHistoryDayKey);
  if (!selectedBucketExists) selectedListeningHistoryDayKey = null;
  const hasSelectedDay = listeningHistoryMode === "overall" && selectedBucketExists;
  dialog.classList.toggle("day-expanded", hasSelectedDay);
  details.hidden = !hasSelectedDay;
  details.innerHTML = hasSelectedDay ? historyDayDetailsMarkup(summary, selectedListeningHistoryDayKey) : "";
  if (hasSelectedDay) {
    requestAnimationFrame(() => {
      dialog.scrollTop = previousDialogScroll;
    });
    $("#closeHistoryDayDetails").onclick = () => {
      selectedListeningHistoryDayKey = null;
      renderListeningHistory();
      requestAnimationFrame(() => $("#listeningHistoryChart .history-bar")?.focus());
    };
  }
  document.querySelectorAll("[data-history-track]").forEach((row) => {
    const openMenu = (event) => openTrackContextMenu(event, row.dataset.historyTrack, { playbackTracks: tracksForActiveProfile(state), playlistID: null });
    row.oncontextmenu = openMenu;
    row.onkeydown = (event) => {
      if (event.target !== row) return;
      if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) {
        event.preventDefault();
        openMenu(event);
      }
    };
  });
}

function openListeningHistory() {
  closeProfileMenu();
  listeningHistoryMode = "overall";
  listeningHistoryWindowOffset = 0;
  listeningHistorySongsExpanded = false;
  ensureListeningHistorySelection();
  renderListeningHistory();
  $("#listeningHistoryDialog").showModal();
}

function activePlaybackMedia() {
  return audio;
}

function playbackIsActive() {
  const media = activePlaybackMedia();
  return Boolean(currentTrack() && !media.paused && !media.ended);
}

function beginListeningSession() {
  const track = currentTrack();
  if (!track) return;
  const historyTrackID = track.transientStream ? track.historyTrackID : track.id;
  if (typeof historyTrackID !== "string" || historyTrackID.length > 128) return;
  const activeEntry = state.listeningHistory.find((entry) => entry.id === activeListeningEntryID);
  if (activeEntry?.trackID === historyTrackID) return;
  const entry = {
    id: crypto.randomUUID(),
    trackID: historyTrackID,
    profileID: track.transientStream ? track.syncProfileID : activeProfileID(),
    serverOrigin: track.transientStream
      ? normalizedServerOrigin(track.sourceServer)
      : normalizedServerOrigin(state.serverURL),
    startedAt: new Date().toISOString(),
    listenedSeconds: 0,
    remoteID: track.remoteID || null,
    title: track.title || null,
    artist: track.artist || null,
    album: track.album || null,
    duration: Number.isFinite(Number(track.duration)) ? Number(track.duration) : null,
    originatedOnThisDevice: true,
  };
  state.listeningHistory = [...state.listeningHistory, entry].slice(-2000);
  activeListeningEntryID = entry.id;
  lastListeningPosition = Number(activePlaybackMedia().currentTime) || 0;
  lastPersistedListeningSeconds = 0;
  persistInBackground();
}

function updateListeningSession() {
  const entry = state.listeningHistory.find((item) => item.id === activeListeningEntryID);
  const media = activePlaybackMedia();
  const position = Number(media.currentTime) || 0;
  if (!entry) {
    lastListeningPosition = position;
    return;
  }
  const delta = position - lastListeningPosition;
  if (!media.paused && delta > 0 && delta < 5) entry.listenedSeconds += delta;
  lastListeningPosition = position;
  if (entry.listenedSeconds - lastPersistedListeningSeconds >= 15) {
    lastPersistedListeningSeconds = entry.listenedSeconds;
    persistInBackground();
    scheduleListeningHistorySync();
    if ($("#listeningHistoryDialog").open) renderListeningHistory();
  }
}

function checkpointListeningSessionForContextChange() {
  const wasPlaying = playbackIsActive();
  if (activeListeningEntryID) updateListeningSession();
  activeListeningEntryID = null;
  lastListeningPosition = 0;
  lastPersistedListeningSeconds = 0;
  return wasPlaying;
}

function finishListeningSessionForReplay() {
  if (activeListeningEntryID) updateListeningSession();
  persistInBackground({ refreshSidebar: false });
  scheduleListeningHistorySync();
  activeListeningEntryID = null;
  lastListeningPosition = 0;
  lastPersistedListeningSeconds = 0;
}

function pendingListeningHistoryBatches() {
  const serverOrigin = normalizedServerOrigin(state.serverURL);
  if (!serverOrigin) return [];
  const tracksByID = new Map(state.tracks.map((track) => [track.id, track]));
  const entriesByProfile = new Map();
  const optionalText = (value, maximumLength) => {
    const text = typeof value === "string" ? value.trim() : "";
    return text ? text.slice(0, maximumLength) : null;
  };
  for (const entry of state.listeningHistory) {
    if (entry.originatedOnThisDevice === false) continue;
    if (normalizedServerOrigin(entry.serverOrigin) !== serverOrigin) continue;
    const listenedSeconds = Math.max(0, Number(entry.listenedSeconds) || 0);
    if (!listeningHistoryEntryQualifiesAsPlay(state, entry)
        || listenedSeconds > 31 * 24 * 60 * 60) continue;
    if (!entry.id || entry.id.length > 128 || !entry.trackID || entry.trackID.length > 128) continue;
    const profileID = entry.profileID || "default";
    const syncKey = `${serverOrigin}#profile=${profileID}#event=${entry.id}`;
    if ((listeningHistorySyncedSeconds.get(syncKey) || 0) >= listenedSeconds) continue;
    const track = tracksByID.get(entry.trackID);
    const remoteID = optionalText(entry.remoteID || track?.remoteID, 128);
    if (!remoteID) continue;
    const upload = {
      syncKey,
      listenedSeconds,
      entry: {
        id: entry.id,
        remoteID,
        startedAt: entry.startedAt,
        listenedSeconds,
      },
    };
    if (!entriesByProfile.has(profileID)) entriesByProfile.set(profileID, []);
    entriesByProfile.get(profileID).push(upload);
  }
  const batches = [];
  for (const [profileID, entries] of entriesByProfile) {
    for (let index = 0; index < entries.length; index += LISTENING_HISTORY_BATCH_SIZE) {
      batches.push({ profileID, entries: entries.slice(index, index + LISTENING_HISTORY_BATCH_SIZE) });
    }
  }
  return batches;
}

function scheduleListeningHistorySync(delay = 1500) {
  clearTimeout(listeningHistorySyncTimer);
  if (!serverToken.trim() || !state.listeningHistory.some((entry) => Number(entry.listenedSeconds) > 0)) return;
  const retryDelay = Math.max(0, listeningHistoryRetryAt - Date.now());
  listeningHistorySyncTimer = setTimeout(() => {
    listeningHistorySyncTimer = null;
    void syncListeningHistoryNow();
  }, Math.max(delay, retryDelay));
}

async function syncListeningHistoryNow({ force = false } = {}) {
  if (!serverToken.trim() || !state.serverURL || (!force && Date.now() < listeningHistoryRetryAt)) return false;
  if (listeningHistorySyncInFlight) {
    listeningHistorySyncPending = true;
    return listeningHistorySyncInFlight;
  }
  listeningHistorySyncInFlight = (async () => {
    let hadFailure = false;
    let context;
    let batches;
    try {
      context = currentProfileContext();
      batches = pendingListeningHistoryBatches();
    } catch {
      return false;
    }
    for (const batch of batches) {
      if (!profileContextIsCurrent(context)) {
        hadFailure = true;
        break;
      }
      try {
        const result = await api.postListeningHistory({
          baseURL: context.serverURL,
          token: context.token,
          profileID: batch.profileID,
          entries: batch.entries.map((item) => item.entry),
        });
        if (result?.supported === false) {
          hadFailure = true;
          continue;
        }
        batch.entries.forEach((item) => listeningHistorySyncedSeconds.set(item.syncKey, item.listenedSeconds));
      } catch {
        hadFailure = true;
      }
    }
    try {
      if (!profileContextIsCurrent(context)) return false;
      const remoteDocument = await api.fetchListeningHistory({
        baseURL: context.serverURL,
        token: context.token,
        profileID: context.profileID,
        limit: 2000,
      });
      if (remoteDocument?.supported !== false && profileContextIsCurrent(context)) {
        if (mergeListeningHistoryDocument(state, remoteDocument, context.profileID, context.serverURL)) {
          await persist({ refreshSidebar: false });
          if ($("#listeningHistoryDialog").open) renderListeningHistory();
          if ($("#nowPlayingDialog").open && fullPlayerQueueTab === "history") renderFullPlayerQueue();
        }
      }
    } catch {
      hadFailure = true;
    }
    listeningHistoryRetryAt = hadFailure ? Date.now() + LISTENING_HISTORY_RETRY_DELAY : 0;
    return !hadFailure;
  })();
  try {
    return await listeningHistorySyncInFlight;
  } finally {
    listeningHistorySyncInFlight = null;
    if (listeningHistorySyncPending) {
      listeningHistorySyncPending = false;
      scheduleListeningHistorySync();
    }
  }
}

function currentSearchQuery() {
  if (section === "library") return libraryQuery;
  if (section === "playlists") return playlistQuery;
  if (section === "storage") return storageQuery;
  if (section === "server") return serverQuery;
  return "";
}

function currentSearchPlaceholder() {
  if (section === "library" && selectedPlaylistID) {
    const playlist = state.playlists.find((item) => item.id === selectedPlaylistID);
    return `Search ${playlist?.name || "this playlist"}…`;
  }
  if (section === "library") return "Search your library…";
  if (section === "playlists") return "Search playlists…";
  if (section === "storage") return storageScope === "downloads" ? "Search downloaded songs…" : storageScope === "files" ? "Search imported files…" : "Search stored songs…";
  if (section === "server") return "Search server library…";
  return "Search Resonance…";
}

function updateTopSearch() {
  const input = $("#search");
  const sort = $("#searchSort");
  document.querySelector(".top-search-group").hidden = section === "settings";
  updateProfileControl();
  input.value = currentSearchQuery();
  input.placeholder = currentSearchPlaceholder();
  input.setAttribute("aria-label", currentSearchPlaceholder());
  if (section === "storage") {
    sort.hidden = false;
    updateSearchSort([
      ["title", "Title"],
      ["recent", "Recently added"],
      ["size", "File size"],
    ], storageSort, "Sort storage results");
  } else if (section === "server") {
    sort.hidden = false;
    updateServerSearchOptions();
  } else {
    closeSearchSort();
    sort.hidden = true;
    $("#searchSortMenu").replaceChildren();
  }
}

function closeSearchSort({ restoreFocus = false } = {}) {
  $("#searchSort").classList.remove("open");
  $("#searchSortButton").setAttribute("aria-expanded", "false");
  if (restoreFocus) $("#searchSortButton").focus();
}

function focusSearchSortOption(direction = 0) {
  const options = [...$("#searchSortMenu").querySelectorAll('[role="option"]:not(:disabled)')];
  if (!options.length) return;
  const focused = options.indexOf(document.activeElement);
  const selected = options.findIndex((option) => option.getAttribute("aria-selected") === "true");
  const base = focused >= 0 ? focused : Math.max(0, selected);
  const index = direction === "first"
    ? 0
    : direction === "last"
      ? options.length - 1
      : (base + direction + options.length) % options.length;
  options[index].focus();
}

function openSearchSort(direction = 0) {
  $("#searchSort").classList.add("open");
  $("#searchSortButton").setAttribute("aria-expanded", "true");
  requestAnimationFrame(() => focusSearchSortOption(direction));
}

function updateSearchSort(options, value, label) {
  const selected = options.find(([optionValue]) => optionValue === value) || options[0];
  $("#searchSortButton").setAttribute("aria-label", label);
  $("#searchSortLabel").textContent = selected[1];
  $("#searchSortMenu").innerHTML = options.map(([optionValue, optionLabel]) => `
    <button type="button" role="option" aria-selected="${optionValue === value}" class="${optionValue === value ? "selected" : ""}" data-search-sort="${optionValue}">
      <span>${optionLabel}</span><svg viewBox="0 0 16 16" aria-hidden="true"><path d="m3.5 8 3 3 6-6"/></svg>
    </button>`).join("");
}

function updateServerSearchOptions() {
  const scopes = [
    ["all", "All"],
    ["device", "On Device"],
    ["available", "Not Downloaded"],
  ];
  const sorts = [
    ["title", "Title"],
    ["artist", "Artist"],
    ["size", "File size"],
  ];
  const selectedScope = scopes.find(([value]) => value === serverScope) || scopes[0];
  const selectedSort = sorts.find(([value]) => value === serverSort) || sorts[0];
  $("#searchSortButton").setAttribute("aria-label", "Filter and sort server results");
  $("#searchSortLabel").textContent = `${selectedScope[1]} · ${selectedSort[1]}`;
  $("#searchSortMenu").innerHTML = `<div class="search-sort-section-label" aria-hidden="true">Filter</div>${scopes.map(([value, label]) => `
    <button type="button" role="option" aria-selected="${value === serverScope}" class="${value === serverScope ? "selected" : ""}" data-search-scope="${value}">
      <span>${label}</span><svg viewBox="0 0 16 16" aria-hidden="true"><path d="m3.5 8 3 3 6-6"/></svg>
    </button>`).join("")}<div class="search-sort-section-label" aria-hidden="true">Sort</div>${sorts.map(([value, label]) => `
    <button type="button" role="option" aria-selected="${value === serverSort}" class="${value === serverSort ? "selected" : ""}" data-search-sort="${value}">
      <span>${label}</span><svg viewBox="0 0 16 16" aria-hidden="true"><path d="m3.5 8 3 3 6-6"/></svg>
    </button>`).join("")}`;
}

function setCurrentSearchQuery(value) {
  if (section === "library") libraryQuery = value;
  else if (section === "playlists") playlistQuery = value;
  else if (section === "storage") storageQuery = value;
  else if (section === "server") serverQuery = value;
}

async function persist({ refreshSidebar = true } = {}) {
  try {
    state = normalizeState(state);
    await api.saveLibrary(state);
    if (refreshSidebar) renderSidebar();
    return true;
  } catch (error) {
    showNotice(error.message || "Resonance could not save your library changes.");
    throw error;
  }
}

function persistInBackground(options) {
  void persist(options).catch(() => {});
}

function normalizedServerKey(value) {
  const url = new URL(String(value || "").trim());
  if (url.protocol !== "https:" && url.protocol !== "http:") throw new Error("Enter a complete http:// or https:// server URL.");
  const loopbackHosts = new Set(["localhost", "127.0.0.1", "[::1]"]);
  const hostname = url.hostname.toLocaleLowerCase().replace(/\.$/, "");
  if (url.protocol !== "https:" && !loopbackHosts.has(hostname)) {
    throw new Error("Use HTTPS before sending server credentials. HTTP is only available for explicit loopback development.");
  }
  if (url.username || url.password) throw new Error("Do not include credentials in the server URL.");
  url.hash = "";
  url.search = "";
  url.pathname = url.pathname.replace(/\/+$/, "") + "/";
  return url.href;
}

function normalizedServerOrigin(value) {
  try { return new URL(normalizedServerKey(value)).origin; }
  catch { return null; }
}

function currentProfileContext() {
  return {
    generation: profileGeneration,
    profileID: activeProfileID(),
    serverURL: state.serverURL,
    serverKey: normalizedServerKey(state.serverURL),
    token: serverToken,
  };
}

function currentServerTransferModes() {
  return resolveServerTransferModes({
    state,
    serverURL: state.serverURL,
    profileID: activeProfileID(),
    config: clientConfig,
    localImportAvailable,
  });
}

async function refreshClientConfig({ force = false } = {}) {
  const requestGeneration = ++clientConfigRequestGeneration;
  let context = null;
  try { context = { ...currentProfileContext(), configToken: serverToken || serverAdminToken }; }
  catch {
    clientConfig = SAFE_CLIENT_CONFIG;
    scheduleClientConfigRenewal();
    return clientConfig;
  }
  if (!context.configToken) {
    clientConfig = SAFE_CLIENT_CONFIG;
    scheduleClientConfigRenewal();
    return clientConfig;
  }
  try {
    const response = await api.fetchClientConfig({
      baseURL: context.serverURL,
      token: context.configToken,
      profileID: context.profileID,
      force,
    });
    if (requestGeneration !== clientConfigRequestGeneration
      || !profileContextIsCurrent(context)
      || context.configToken !== (serverToken || serverAdminToken)) return clientConfig;
    clientConfig = response?.config && typeof response.config === "object"
      ? { ...response.config, source: response.source === "remote" ? "remote" : (response.source || "cache") }
      : SAFE_CLIENT_CONFIG;
  } catch {
    if (requestGeneration !== clientConfigRequestGeneration
      || !profileContextIsCurrent(context)
      || context.configToken !== (serverToken || serverAdminToken)) return clientConfig;
    clientConfig = SAFE_CLIENT_CONFIG;
  }
  scheduleClientConfigRenewal();
  if (activeServerStream && currentServerTransferModes().downloadMode !== "stream_only") {
    releaseActiveServerStream({ stopPlayback: true });
    showNotice("Streaming stopped because the signed server policy no longer authorizes stream-only playback.");
  }
  return clientConfig;
}

function scheduleClientConfigRenewal() {
  if (clientConfigRenewalTimer) clearTimeout(clientConfigRenewalTimer);
  clientConfigRenewalTimer = null;
  if (!(serverToken || serverAdminToken)) return;
  const delay = clientConfigRenewalDelay(clientConfig);
  clientConfigRenewalTimer = setTimeout(async () => {
    clientConfigRenewalTimer = null;
    await refreshClientConfig({ force: true });
    persistInBackground({ refreshSidebar: false });
    if (section === "server") renderServer();
  }, delay);
}

function profileContextIsCurrent(context) {
  try {
    return context.generation === profileGeneration
      && context.profileID === activeProfileID()
      && context.serverKey === normalizedServerKey(state.serverURL)
      && context.token === serverToken;
  } catch {
    return false;
  }
}

function playableActiveRemoteTrack(remoteID) {
  const track = activeRemoteTrack(remoteID);
  return track && track.available !== false && !track.missing && typeof track.fileUrl === "string" && track.fileUrl
    ? track
    : null;
}

function releaseServerStreamCapability(stream) {
  if (!stream?.url) return Promise.resolve(false);
  return api.releaseServerStream(stream.url).catch(() => false);
}

function releaseActiveServerStream({ stopPlayback = false, invalidatePending = true } = {}) {
  if (invalidatePending) serverStreamRequestGeneration += 1;
  const stream = activeServerStream;
  if (!stream) return false;
  const ownsPlayback = currentID === stream.track.id;
  if (stopPlayback && ownsPlayback) {
    updateListeningSession();
    scheduleListeningHistorySync();
    activeListeningEntryID = null;
    audio.pause();
    audio.removeAttribute("src");
    audio.load();
    audioSourceTrackID = null;
    audioMetadataTrackID = null;
    currentID = null;
    state.currentTrackID = null;
    state.position = 0;
    activePlaybackQueueIDs = activePlaybackQueueIDs.filter((id) => id !== stream.track.id);
    activePlaybackSourceQueueIDs = activePlaybackSourceQueueIDs.filter((id) => id !== stream.track.id);
    state.playbackQueueIDs = persistentPlaybackQueueIDs(activePlaybackQueueIDs);
    state.playbackSourceQueueIDs = persistentPlaybackQueueIDs(activePlaybackSourceQueueIDs);
  }
  activeServerStream = null;
  void releaseServerStreamCapability(stream);
  if (stopPlayback && ownsPlayback) {
    persistInBackground({ refreshSidebar: false });
    updateChrome();
    render();
  }
  return true;
}

async function playRemoteStream(song) {
  const cachedTrack = playableActiveRemoteTrack(song?.id);
  if (cachedTrack) {
    play(cachedTrack, tracksForActiveProfile(state), { playlistID: null });
    return;
  }
  if (!song?.id || !serverToken.trim()) {
    showNotice("Sign in to your Resonance account before streaming this song.");
    return;
  }
  if (serverSongRequiresDownload(song)) {
    showNotice("Windows stream-only playback supports audio songs. Switch to Verified file cache and download this video to watch it.");
    return;
  }
  if (currentServerTransferModes().downloadMode !== "stream_only") {
    showNotice("Stream-only playback is not enabled by the current signed server policy.");
    return;
  }
  const context = currentProfileContext();
  const requestGeneration = ++serverStreamRequestGeneration;
  try {
    const result = await api.createServerStream({
      baseURL: context.serverURL,
      token: context.token,
      profileID: context.profileID,
      songID: song.id,
    });
    const streamURL = typeof result?.url === "string" ? result.url : "";
    const historyTrackID = typeof result?.historyTrackID === "string" ? result.historyTrackID : "";
    const stale = requestGeneration !== serverStreamRequestGeneration
      || !profileContextIsCurrent(context)
      || currentServerTransferModes().downloadMode !== "stream_only";
    if (stale
        || !/^resonance-stream:\/\/media\/[a-f0-9]{64}$/.test(streamURL)
        || !/^remote-stream:[a-f0-9]{64}$/.test(historyTrackID)) {
      if (streamURL) await api.releaseServerStream(streamURL).catch(() => false);
      if (!stale) throw new Error("The server returned an invalid stream capability.");
      return;
    }
    const previousStream = activeServerStream;
    const duration = Number(song.duration_seconds ?? song.duration) || 0;
    const track = Object.freeze({
      id: `stream:${crypto.randomUUID()}`,
      remoteID: song.id,
      title: song.title || song.name || "Untitled",
      artist: song.artist || "Unknown Artist",
      album: song.album || "Server Library",
      duration: duration > 0 ? duration : 0,
      artwork: typeof song.artwork === "string" && song.artwork.startsWith("data:") ? song.artwork : null,
      artworkURL: song.artwork_url || song.artworkURL || null,
      filePath: null,
      fileUrl: streamURL,
      available: true,
      transientStream: true,
      historyTrackID,
      sourceServer: normalizedServerOrigin(context.serverURL),
      syncProfileID: context.profileID,
      contentSha256: typeof song.content_sha256 === "string" ? song.content_sha256 : null,
      size: Number(song.size) || 0,
    });
    activeServerStream = { url: streamURL, track, context };
    if (previousStream) void releaseServerStreamCapability(previousStream);
    play(track, [track], { playlistID: null });
  } catch (error) {
    if (requestGeneration !== serverStreamRequestGeneration || !profileContextIsCurrent(context)) return;
    showNotice(friendlyIPCError(error, "This song could not be streamed from the server."));
  }
}

function currentServerUploadContext() {
  return Object.freeze({
    ...currentProfileContext(),
    adminToken: serverAdminToken,
    profileName: activeProfile().name || "the active server profile",
  });
}

function serverUploadContextIsCurrent(context) {
  return profileContextIsCurrent(context) && context?.adminToken === serverAdminToken;
}

function localImportServerContextError() {
  return {
    stage: "syncing",
    code: "SERVER_CONTEXT_CHANGED",
    message: "The server or profile changed during the import. The local file was kept; start its upload again.",
  };
}

function requireLocalImportServerContext(context) {
  if (!serverUploadContextIsCurrent(context)) throw localImportServerContextError();
}

function reserveServerContext(context) {
  requireLocalImportServerContext(context);
  if (serverContextReservation) throw new Error("Another import is already using the server connection.");
  serverContextReservation = context;
}

function releaseServerContext(context) {
  if (serverContextReservation === context) serverContextReservation = null;
}

function ensureServerContextCanChange() {
  if (serverTransferActive || serverContextReservation) {
    throw new Error("Wait for the current transfer to finish before changing the server or profile.");
  }
}

function serverArtworkKey(song) {
  return `${normalizedServerKey(state.serverURL)}#${activeProfileID()}#${song.id}#${song.modified_at || song.modified_utc || ""}`;
}

function updateServerArtworkNode(song) {
  if (section !== "server") return;
  const songID = String(song?.id || "");
  const container = [...document.querySelectorAll("[data-server-artwork-id]")]
    .find((element) => element.dataset.serverArtworkId === songID);
  if (!container) return;
  const source = song?.artwork;
  const canRenderImage = source && !/^https?:/i.test(source);
  container.querySelector("img")?.remove();
  container.classList.remove("loaded", "has-image", "failed");
  if (!canRenderImage) {
    container.classList.add("failed");
    container.setAttribute("aria-busy", "false");
    return;
  }
  const image = document.createElement("img");
  image.alt = "";
  image.dataset.squareArtwork = "";
  container.append(image);
  container.classList.add("has-image");
  container.setAttribute("aria-busy", "true");
  bindServerArtworkLoadState(container);
  image.src = source;
}

async function hydrateServerArtwork(song) {
  const source = song.artwork || song.artwork_url;
  if (!source || String(source).startsWith("data:") || String(source).startsWith("file:")) return;
  const key = serverArtworkKey(song);
  const cached = serverArtworkCache.get(key);
  if (cached) {
    song.artwork = cached;
    updateServerArtworkNode(song);
    return;
  }
  let pending = serverArtworkPending.get(key);
  const context = currentProfileContext();
  if (!pending) {
    pending = api.fetchServerArtwork({
      baseURL: context.serverURL,
      token: context.token,
      profileID: context.profileID,
      songID: song.id,
    });
    serverArtworkPending.set(key, pending);
  }
  try {
    const dataURL = await pending;
    if (!profileContextIsCurrent(context)) return;
    if (!dataURL) return;
    if (serverArtworkCache.size >= 256) serverArtworkCache.delete(serverArtworkCache.keys().next().value);
    serverArtworkCache.set(key, dataURL);
    song.artwork = dataURL;
    updateServerArtworkNode(song);
  } catch {
    song.artwork = null;
    updateServerArtworkNode(song);
  } finally {
    if (serverArtworkPending.get(key) === pending) serverArtworkPending.delete(key);
  }
}

function hydrateServerCatalogArtwork(songs) {
  const queue = songs.filter((song) => song.artwork || song.artwork_url);
  const workers = Array.from({ length: Math.min(4, queue.length) }, async () => {
    while (queue.length) await hydrateServerArtwork(queue.shift());
  });
  void Promise.allSettled(workers);
}

function hydrateServerCatalogMetadata(songs) {
  const context = currentProfileContext();
  const generation = serverCatalogGeneration;
  const queue = songs.filter((song) =>
    !activeRemoteTrack(song?.id)
      && song?.source_url
      && !serverSourceNeedsOriginalPage(song.source_url));
  const workers = Array.from({ length: Math.min(3, queue.length) }, async () => {
    while (queue.length) {
      const song = queue.shift();
      let metadata;
      try {
        metadata = await api.resolveServerSourceMetadata({
          sourceURL: song.source_url,
          mediaKind: song.media_kind,
        });
      } catch {
        if (generation !== serverCatalogGeneration || !profileContextIsCurrent(context)) return;
        const current = serverCatalog.find((item) => item.id === song.id && item.source_url === song.source_url);
        if (current) {
          const fallback = serverSourceDisplayFallback(song.source_url, { failed: true });
          Object.assign(current, fallback, { name: fallback.title });
          if (section === "server") renderServer();
        }
        continue;
      }
      if (generation !== serverCatalogGeneration || !profileContextIsCurrent(context)) return;
      const current = serverCatalog.find((item) => item.id === song.id && item.source_url === song.source_url);
      if (!current) continue;
      current.title = metadata?.title || current.title;
      current.name = metadata?.title || current.name;
      current.artist = metadata?.artist || current.artist;
      current.album = metadata?.album || "Imported";
      current.duration = Number(metadata?.duration) > 0 ? Number(metadata.duration) : current.duration;
      if (metadata?.artworkURL) {
        const artwork = await api.fetchLocalImportArtwork(metadata.artworkURL).catch(() => null);
        if (generation !== serverCatalogGeneration || !profileContextIsCurrent(context)) return;
        if (artwork) current.artwork = artwork;
      }
      if (section === "server") renderServer();
    }
  });
  void Promise.allSettled(workers);
}

function replaceServerCatalog(songs) {
  serverCatalog = (Array.isArray(songs) ? songs : []).map((song) => {
    const local = activeRemoteTrack(song?.id);
    const sourceFallback = serverSourceDisplayFallback(song?.source_url);
    const fallbackTitle = song?.source_url
      ? sourceFallback.title
      : `Saved song ${String(song?.id || "").slice(0, 8)}`;
    return {
      ...song,
      name: local?.title || song?.name || song?.filename || fallbackTitle,
      title: local?.title || song?.title || fallbackTitle,
      artist: local?.artist || song?.artist || (song?.source_url ? sourceFallback.artist : "Unknown Artist"),
      album: local?.album || song?.album || (song?.source_url ? sourceFallback.album : "Server Library"),
      duration: Number(local?.duration) > 0 ? Number(local.duration) : Number(song?.duration) || null,
      artwork: local?.artwork || song?.artwork || null,
    };
  });
  serverCatalogGeneration += 1;
  hydrateServerCatalogMetadata(serverCatalog);
}

function markPlaylistDirty(playlist) {
  if (!playlist || playlist.isSystem) return;
  playlistMutationGeneration += 1;
  const id = playlist.id.toLocaleLowerCase();
  state.dirtyPlaylistIDs = [...new Set([...state.dirtyPlaylistIDs, id])];
  state.deletedPlaylistIDs = state.deletedPlaylistIDs.filter((item) => item !== id);
}

function upsertImportedPlaylist(name, trackIDs) {
  const cleanName = String(name || "Imported Playlist").trim() || "Imported Playlist";
  const orderedIDs = [...new Set(trackIDs)].filter((id) => state.tracks.some((track) => track.id === id));
  if (!orderedIDs.length) return null;
  let playlist = state.playlists.find((item) =>
    !item.isSystem && item.name.localeCompare(cleanName, undefined, { sensitivity: "accent" }) === 0);
  if (!playlist) {
    playlist = {
      id: crypto.randomUUID().toLocaleLowerCase(),
      name: cleanName,
      trackIDs: [],
      remoteSongIDs: [],
      isSystem: false,
    };
    state.playlists.push(playlist);
  }
  playlist.trackIDs = [...new Set([...(playlist.trackIDs || []), ...orderedIDs])];
  updatePlaylistRemoteSongIDs(state, playlist);
  markPlaylistDirty(playlist);
  return playlist;
}

function markPlaylistDeleted(playlist) {
  if (!playlist || playlist.isSystem) return;
  playlistMutationGeneration += 1;
  const id = playlist.id.toLocaleLowerCase();
  state.dirtyPlaylistIDs = state.dirtyPlaylistIDs.filter((item) => item !== id);
  state.deletedPlaylistIDs = [...new Set([...state.deletedPlaylistIDs, id])];
}

function schedulePlaylistSync() {
  clearTimeout(playlistSyncTimer);
  if (!serverToken.trim()) return;
  playlistSyncTimer = setTimeout(() => syncPlaylistsNow({ automatic: true }), 500);
}

async function syncPlaylistsNow({ automatic = false } = {}) {
  if (playlistSyncInFlight) {
    playlistSyncPending = true;
    return playlistSyncInFlight;
  }
  const context = currentProfileContext();
  playlistSyncInFlight = (async () => {
    if (!serverToken.trim()) {
      if (!automatic) showNotice("Sign in to your Resonance account.");
      return;
    }

    try {
      const serverKey = `${context.serverKey}#profile=${context.profileID}`;
      if (state.playlistSyncServerURL !== serverKey) {
        state.playlistSyncServerURL = serverKey;
        state.playlistRevision = 0;
        state.knownRemotePlaylistIDs = [];
        state.deletedPlaylistIDs = [];
        state.dirtyPlaylistIDs = state.playlists.filter((playlist) => !playlist.isSystem).map((playlist) => playlist.id);
      }

      let remoteDocument = await api.fetchPlaylists({
        baseURL: context.serverURL,
        token: context.token,
        profileID: context.profileID,
      });
      if (!profileContextIsCurrent(context)) return;
      for (let attempt = 0; attempt < 2; attempt += 1) {
        const merge = mergePlaylistDocument(state, remoteDocument);
        if (!merge.needsUpload) {
          applyRemotePlaylistDocument(state, remoteDocument);
          enforceCurrentClipRange();
          await persist();
          render();
          return;
        }

        const submittedPlaylistGeneration = playlistMutationGeneration;
        const submittedDirtyPlaylistIDs = [...state.dirtyPlaylistIDs];
        const submittedDeletedPlaylistIDs = [...state.deletedPlaylistIDs];
        const submittedLikesGeneration = likesMutationGeneration;
        const submittedDirtyLikeIDs = [...state.dirtyRemoteLikeSongIDs];
        const submittedClipRangeGeneration = clipRangeMutationGeneration;
        const submittedDirtyClipRangeKeys = [...state.dirtyClipRangeKeys];
        const submittedDeletedClipRangeKeys = [...state.deletedClipRangeKeys];
        const result = await api.putPlaylists({
          baseURL: context.serverURL,
          token: context.token,
          profileID: context.profileID,
          document: merge.document,
        });
        if (!profileContextIsCurrent(context)) return;
        if (result.status === 200) {
          if ((submittedDirtyClipRangeKeys.length || submittedDeletedClipRangeKeys.length)
              && !Array.isArray(result.document?.clip_ranges)) {
            throw new Error("The music server does not support synced clip ranges yet.");
          }
          if (playlistMutationGeneration === submittedPlaylistGeneration) {
            state.dirtyPlaylistIDs = state.dirtyPlaylistIDs.filter((id) => !submittedDirtyPlaylistIDs.includes(id));
            state.deletedPlaylistIDs = state.deletedPlaylistIDs.filter((id) => !submittedDeletedPlaylistIDs.includes(id));
          }
          if (likesMutationGeneration === submittedLikesGeneration) {
            state.dirtyRemoteLikeSongIDs = state.dirtyRemoteLikeSongIDs.filter((id) => !submittedDirtyLikeIDs.includes(id));
          }
          if (clipRangeMutationGeneration === submittedClipRangeGeneration) {
            state.dirtyClipRangeKeys = state.dirtyClipRangeKeys.filter((key) => !submittedDirtyClipRangeKeys.includes(key));
            state.deletedClipRangeKeys = state.deletedClipRangeKeys.filter((key) => !submittedDeletedClipRangeKeys.includes(key));
          }
          state.likesDirty = state.dirtyRemoteLikeSongIDs.length > 0;
          applyRemotePlaylistDocument(state, result.document, {
            preservingLocalIDs: playlistMutationGeneration === submittedPlaylistGeneration
              ? []
              : state.dirtyPlaylistIDs,
            preservingLocalClipKeys: clipRangeMutationGeneration === submittedClipRangeGeneration
              ? []
              : state.dirtyClipRangeKeys,
          });
          enforceCurrentClipRange();
          await persist();
          render();
          if (state.dirtyPlaylistIDs.length || state.deletedPlaylistIDs.length || state.likesDirty
              || state.dirtyClipRangeKeys.length || state.deletedClipRangeKeys.length) {
            playlistSyncPending = true;
          }
          return;
        }
        remoteDocument = result.document;
      }
      throw new Error("Playlist sync conflicted; try again");
    } catch (error) {
      if (profileContextIsCurrent(context) && !automatic) showNotice(`Playlist sync failed: ${error.message || "Unknown error"}`);
    }
  })();

  try {
    await playlistSyncInFlight;
  } finally {
    playlistSyncInFlight = null;
    if (playlistSyncPending) {
      playlistSyncPending = false;
      queueMicrotask(() => syncPlaylistsNow({ automatic: true }));
    }
  }
}

function artwork(track, { animateLoading = false } = {}) {
  const source = track?.artwork;
  const hasRemoteArtwork = animateLoading && Boolean(source || track?.artwork_url);
  const canRenderImage = source && !/^https?:/i.test(source);
  if (!hasRemoteArtwork) {
    return `<div class="row-art">${source ? squareArtworkImageMarkup(source) : "♪"}</div>`;
  }
  return `<div class="row-art server-artwork-loading${canRenderImage ? " has-image" : ""}" data-server-artwork-id="${escapeHTML(track?.id || "")}" aria-busy="true">
    <span class="server-artwork-placeholder" aria-hidden="true">♪</span>
    ${canRenderImage ? squareArtworkImageMarkup(source) : ""}
  </div>`;
}

function playlistArtworkMarkup(playlist, { className = "playlist-art", tagName = "div" } = {}) {
  const trackIDs = playlistArtworkTrackIDs(playlist);
  const classes = `playlist-artwork ${className}`;
  if (!trackIDs.length) {
    return `<${tagName} class="${classes} playlist-artwork-fallback" aria-hidden="true">${playlist?.isSystem ? "♥" : "♪"}</${tagName}>`;
  }

  const tracksByID = new Map(state.tracks.map((track) => [track.id, track]));
  const cells = Array.from({ length: 4 }, (_, index) => {
    const source = tracksByID.get(trackIDs[index])?.artwork;
    const canRenderImage = typeof source === "string" && source && !/^https?:/i.test(source);
    return `<span class="playlist-artwork-cell">${canRenderImage ? squareArtworkImageMarkup(source) : "♪"}</span>`;
  }).join("");
  return `<${tagName} class="${classes} playlist-artwork-collage" aria-hidden="true">${cells}</${tagName}>`;
}

function displayAlbum(track) {
  const album = String(track?.album || "").trim();
  return !album || album.toLocaleLowerCase() === "imported" ? "Unknown Album" : album;
}

function bindServerArtworkLoadState(container) {
  const image = container.querySelector("img");
  if (!image || image.dataset.loadStateBound === "true") return;
  image.dataset.loadStateBound = "true";
  const reveal = () => {
    container.classList.add("loaded");
    container.classList.remove("failed");
    container.setAttribute("aria-busy", "false");
  };
  const fail = () => {
    container.classList.remove("has-image", "loaded");
    container.classList.add("failed");
    container.setAttribute("aria-busy", "false");
    image.remove();
  };
  image.addEventListener("load", reveal, { once: true });
  image.addEventListener("error", fail, { once: true });
  if (image.complete && image.getAttribute("src")) image.naturalWidth ? reveal() : fail();
}

function bindServerArtworkLoadStates() {
  document.querySelectorAll(".server-artwork-loading.has-image").forEach(bindServerArtworkLoadState);
}

function recentTrackItem(track) {
  const title = track.title || "Untitled";
  const artist = track.artist || "Unknown Artist";
  return `<button class="recent-track-item" type="button" data-recent-track="${escapeHTML(track.id)}" aria-label="Play ${escapeHTML(title)} by ${escapeHTML(artist)}">
    <span class="recent-track-art">${track?.artwork ? squareArtworkImageMarkup(track.artwork) : "<span aria-hidden=\"true\">♪</span>"}<span class="recent-track-play" aria-hidden="true">${playbackPlayIcon}</span></span>
    <span class="recent-track-copy"><strong>${escapeHTML(title)}</strong><small>${escapeHTML(artist)}</small></span>
  </button>`;
}

function trackRow(track, index) {
  const liked = state.favorites.includes(track.id);
  const mediaKind = isInstalledVideoTrack(track) ? "Video" : "Audio";
  const unavailable = track.available === false || track.missing;
  const editablePlaylist = state.playlists.find((playlist) => playlist.id === selectedPlaylistID && !playlist.isSystem);
  const actionLabel = unavailable
    ? `${track.title || "Untitled"} by ${track.artist || "Unknown artist"}. File unavailable on this device`
    : `Play ${track.title || "Untitled"} by ${track.artist || "Unknown artist"}`;
  const reorderLabel = editablePlaylist ? ". Press Alt+Up or Alt+Down to reorder" : "";
  const draggableAttributes = editablePlaylist
    ? ` data-playlist-draggable="true" aria-keyshortcuts="Alt+ArrowUp Alt+ArrowDown Shift+F10"`
    : ` aria-keyshortcuts="Enter Space Shift+F10"`;
  return `<div class="track-row ${track.id === currentID ? "playing" : ""}${editablePlaylist ? " playlist-draggable" : ""}${unavailable ? " unavailable" : ""}" data-track="${escapeHTML(track.id)}" tabindex="0" aria-label="${escapeHTML(actionLabel + reorderLabel)}" aria-disabled="${unavailable}"${draggableAttributes}>
    <span class="track-number" title="${track.id === currentID && !audio.paused ? "Now playing" : `Track ${index + 1}`}">${track.id === currentID && !audio.paused ? nowPlayingIcon : index + 1}</span>${artwork(track)}
    <div class="track-copy"><strong>${escapeHTML(track.title)}</strong><small>${escapeHTML(track.artist)} / ${unavailable ? "File unavailable" : mediaKind}</small></div>
    <span class="album">${escapeHTML(displayAlbum(track))}</span><span class="track-time">${unavailable ? "Missing" : formatTime(track.duration)}</span>
    <button type="button" class="heart" data-favorite="${escapeHTML(track.id)}" aria-label="${liked ? "Remove from" : "Add to"} Liked Songs" aria-pressed="${liked}">${liked ? "♥" : "♡"}</button>
  </div>`;
}

function schedulePlaybackProgressSave() {
  if (playbackProgressTimer) return;
  playbackProgressTimer = setTimeout(() => {
    playbackProgressTimer = null;
    persistInBackground({ refreshSidebar: false });
  }, 5000);
}

function renderLibrary() {
  const previousRecentTrackList = document.querySelector(".recent-track-list");
  if (previousRecentTrackList) recentlyAddedScrollLeft = previousRecentTrackList.scrollLeft;
  updateTopSearch();
  const tracks = filterTracks(playlistTracks(), libraryQuery, libraryFilter);
  const recentTracks = !selectedPlaylistID ? filterTracks(tracks, "", "recent").filter((track) => track.available !== false) : [];
  const selectedPlaylist = selectedPlaylistID ? state.playlists.find((item) => item.id === selectedPlaylistID) : null;
  const title = selectedPlaylist?.name || (selectedPlaylistID ? "Playlist" : "Library");
  const editablePlaylist = Boolean(selectedPlaylist && !selectedPlaylist.isSystem);
  const collectionPlaying = isCurrentCollectionPlayback(tracks) && !audio.paused;
  const playlistMenuItems = selectedPlaylist ? [
    `<button type="button" role="menuitem" data-hero-import>Import Songs…</button>`,
    tracks.length ? `<button type="button" role="menuitem" data-hero-next>Next Track</button>` : "",
    `<button type="button" role="menuitem" data-hero-sync>Sync Playlists</button>`,
    editablePlaylist ? `<button class="danger-item" type="button" role="menuitem" data-hero-delete>Delete Playlist</button>` : "",
  ].filter(Boolean).join("") : "";
  const playlistMoreMenu = selectedPlaylist
    ? `<details class="playlist-more" id="playlistMore"><summary title="More options" aria-label="More playlist options"><span aria-hidden="true">•••</span></summary><div class="playlist-menu" role="menu">${playlistMenuItems}</div></details>`
    : "";
  const playlistCapsule = selectedPlaylist
    ? `<div class="playlist-action-cluster"><button class="${shuffle ? "active" : ""}" id="heroShuffle" title="${currentTrack()?.transientStream ? "Unavailable for one-song server playback" : "Shuffle"}" aria-label="${currentTrack()?.transientStream ? "Unavailable for one-song server playback" : "Shuffle"}" aria-pressed="${shuffle}" ${tracks.length && !currentTrack()?.transientStream ? "" : "disabled"}>${shuffleIcon}</button><button id="heroAdd" title="Add songs" aria-label="Add songs">${plusIcon}</button>${playlistMoreMenu}</div>`
    : "";
  const libraryFilters = `<div class="filters${selectedPlaylistID ? "" : " library-top-filters"}" role="group" aria-label="Library filter"><button class="${libraryFilter === "all" ? "active" : ""}" data-library-filter="all" aria-pressed="${libraryFilter === "all"}">All songs</button><button class="${libraryFilter === "recent" ? "active" : ""}" data-library-filter="recent" aria-pressed="${libraryFilter === "recent"}">Recently added</button><button class="${libraryFilter === "audio" ? "active" : ""}" data-library-filter="audio" aria-pressed="${libraryFilter === "audio"}">Audio</button><button class="${libraryFilter === "video" ? "active" : ""}" data-library-filter="video" aria-pressed="${libraryFilter === "video"}">Video</button></div>`;
  const hasLibraryFilter = Boolean(libraryQuery.trim()) || libraryFilter !== "all";
  const emptyLibraryTitle = hasLibraryFilter ? "No matching songs" : selectedPlaylistID ? "This playlist is empty" : "No songs yet";
  const emptyLibraryHelp = hasLibraryFilter ? "Try another search or filter." : selectedPlaylistID ? "Like songs or add them from your Library." : "Import audio files or connect your music server.";
  const collectionHeader = selectedPlaylistID
    ? `<div class="hero">${playlistArtworkMarkup(selectedPlaylist, { className: "hero-art" })}<div><span class="eyebrow">PLAYLIST</span><h1>${escapeHTML(title)}</h1><p>${tracks.length} tracks / Stored locally</p><div class="hero-actions"><button class="primary playlist-play" id="playCollection" ${tracks.length ? "" : "disabled"}><span class="button-icon">${collectionPlaying ? playbackPauseIcon : playbackPlayIcon}</span><span>${collectionPlaying ? "Pause" : "Play"}</span></button>${playlistCapsule}</div></div></div>`
    : libraryFilters;
  content.innerHTML = `<div class="collection-scroll">${collectionHeader}
    ${recentTracks.length ? `<section class="recently-added" aria-labelledby="recentlyAddedTitle"><div class="section-heading"><div><span class="eyebrow">FRESH TO YOUR LIBRARY</span><h2 id="recentlyAddedTitle">Recently Added</h2></div><span>${recentTracks.length} newest</span></div><div class="recent-track-list">${recentTracks.map(recentTrackItem).join("")}</div></section>` : ""}
    ${selectedPlaylistID ? libraryFilters : ""}
    <div class="track-table"><div class="track-header"><span>#</span><span></span><span>Title</span><span>Album</span><span>Time</span><span></span></div>
    ${tracks.length ? tracks.map(trackRow).join("") : `<div class="empty"><b>${emptyLibraryTitle}</b><span>${emptyLibraryHelp}</span></div>`}</div></div>`;
  const recentTrackList = document.querySelector(".recent-track-list");
  if (recentTrackList) {
    recentTrackList.scrollLeft = recentlyAddedScrollLeft;
    recentTrackList.onscroll = () => {
      recentlyAddedScrollLeft = recentTrackList.scrollLeft;
    };
  }
  bindTrackRows(tracks);
  if ($("#playCollection")) $("#playCollection").onclick = () => {
    if (isCurrentCollectionPlayback(tracks)) toggle();
    else {
      const firstPlayable = tracks.find((track) => track.available !== false);
      if (firstPlayable) play(firstPlayable, tracks, { playlistID: selectedPlaylistID });
    }
  };
  if ($("#heroShuffle")) $("#heroShuffle").onclick = () => {
    setShuffleEnabled(!shuffle);
    render();
  };
  if ($("#heroAdd") && selectedPlaylist) $("#heroAdd").onclick = () => openAddSongsDialog(selectedPlaylist);
  const closePlaylistMoreMenu = () => $("#playlistMore")?.removeAttribute("open");
  const importButton = document.querySelector("[data-hero-import]");
  if (importButton) importButton.onclick = () => { closePlaylistMoreMenu(); importAudio(); };
  const nextButton = document.querySelector("[data-hero-next]");
  if (nextButton) nextButton.onclick = () => { closePlaylistMoreMenu(); move(1); };
  const syncButton = document.querySelector("[data-hero-sync]");
  if (syncButton) syncButton.onclick = () => { closePlaylistMoreMenu(); syncPlaylistsNow(); };
  document.querySelectorAll("[data-recent-track]").forEach((button) => {
    button.onpointerenter = () => button.classList.add("hovering");
    button.onpointerleave = () => button.classList.remove("hovering");
    button.onpointercancel = () => button.classList.remove("hovering");
    button.onclick = () => {
      const track = state.tracks.find((item) => item.id === button.dataset.recentTrack);
      if (!track) return;
      track.id === currentID ? toggle() : play(track, tracks, { playlistID: null });
    };
    button.oncontextmenu = (event) => openTrackContextMenu(event, button.dataset.recentTrack, { playbackTracks: tracks, playlistID: null });
    button.onkeydown = (event) => {
      if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) {
        event.preventDefault();
        openTrackContextMenu(event, button.dataset.recentTrack, { playbackTracks: tracks, playlistID: null });
      }
    };
  });
  const deleteButton = document.querySelector("[data-hero-delete]");
  if (deleteButton) deleteButton.onclick = async () => {
    closePlaylistMoreMenu();
    await deletePlaylistFromContext(selectedPlaylist);
  };
  document.querySelectorAll("[data-library-filter]").forEach((button) => button.onclick = () => {
    libraryFilter = button.dataset.libraryFilter;
    renderLibrary();
  });
}

function renderPlaylists() {
  updateTopSearch();
  const playlists = filterPlaylists(state.playlists, tracksForActiveProfile(state), playlistQuery);
  content.innerHTML = `<div class="page"><span class="eyebrow">YOUR COLLECTIONS</span><h1>Playlists</h1><p>Organize your music into collections shared across your Resonance devices.</p><div class="playlist-page-actions"><button class="primary" id="pageNewPlaylist">＋ New Playlist</button><button class="secondary" id="pageSyncPlaylists">Sync Playlists</button></div><div class="playlist-grid">${playlists.map((playlist) => `<button class="playlist-card" data-open-playlist="${escapeHTML(playlist.id)}" aria-keyshortcuts="Shift+F10">${playlistArtworkMarkup(playlist)}<div><strong>${escapeHTML(playlist.name)}</strong><small>${playlist.trackIDs.length} tracks</small></div><span>›</span></button>`).join("") || `<div class="empty"><b>No matching playlists</b><span>Try a different playlist or song name.</span></div>`}</div></div>`;
  $("#pageNewPlaylist").onclick = () => newPlaylist();
  $("#pageSyncPlaylists").onclick = () => syncPlaylistsNow();
  document.querySelectorAll("[data-open-playlist]").forEach((button) => {
    button.onclick = () => navigate("library", button.dataset.openPlaylist);
    button.oncontextmenu = (event) => openPlaylistContextMenu(event, button.dataset.openPlaylist);
    button.onkeydown = (event) => {
      if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) {
        event.preventDefault();
        openPlaylistContextMenu(event, button.dataset.openPlaylist);
      }
    };
  });
}

function formatBytes(value) {
  const bytes = Math.max(0, Number(value) || 0);
  if (bytes < 1024) return `${bytes.toFixed(0)} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let size = bytes / 1024;
  let unit = units[0];
  for (let index = 1; index < units.length && size >= 1024; index += 1) {
    size /= 1024;
    unit = units[index];
  }
  return `${size >= 10 ? size.toFixed(1) : size.toFixed(2)} ${unit}`;
}

function storageTracks() {
  let tracks = tracksForActiveProfile(state).filter((track) => {
    const storageClass = physicalStorageClassForTrack(track);
    if (storageScope === "downloads" && storageClass !== "downloads") return false;
    if (storageScope === "files" && storageClass === "downloads") return false;
    const haystack = `${track.title || ""} ${track.artist || ""} ${track.album || ""} ${track.filePath || ""}`.toLocaleLowerCase();
    return haystack.includes(storageQuery.toLocaleLowerCase());
  });
  tracks = [...tracks].sort((left, right) => {
    if (storageSort === "size") return (right.size || 0) - (left.size || 0);
    if (storageSort === "recent") return String(right.dateAdded || "").localeCompare(String(left.dateAdded || ""));
    return String(left.title || "").localeCompare(String(right.title || ""));
  });
  return tracks;
}

async function deleteStoredTracks(trackIDs) {
  const tracks = state.tracks.filter((track) => trackIDs.includes(track.id));
  if (!tracks.length) return;
  const targetIDs = new Set(tracks.map((track) => track.id));
  const releasedCurrentTrack = targetIDs.has(currentID)
    ? {
        track: currentTrack(),
        position: Math.max(0, Number(audio.currentTime) || Number(state.position) || 0),
        wasPlaying: playbackIsActive(),
      }
    : null;

  if (targetIDs.has($("#clipEditorTrack")?.value)) {
    await stopClipRangePreview({ resumeMain: false, unload: true });
  }
  if (installedVideoSession && targetIDs.has(installedVideoSession.trackID)) {
    const session = installedVideoSession;
    installedVideoPlayer.pause();
    finishInstalledVideoClose({ session });
  }
  if (releasedCurrentTrack) {
    audio.pause();
    audio.removeAttribute("src");
    audio.load();
    audioSourceTrackID = null;
    audioMetadataTrackID = null;
    pendingRestorePosition = null;
  }

  const deleted = [];
  const failed = [];
  for (const track of tracks) {
    try {
      if (track.available !== false && track.filePath) await api.deleteAudio(track.filePath);
      deleted.push(track);
    } catch (error) {
      failed.push({ track, error });
    }
  }
  const removed = new Set(deleted.map((track) => track.id));
  let playlistMembershipChanged = false;
  state.playlists.filter((playlist) => !playlist.isSystem).forEach((playlist) => {
    const previousTrackIDs = playlist.trackIDs || [];
    if (!previousTrackIDs.some((id) => removed.has(id))) return;
    playlist.trackIDs = previousTrackIDs.filter((id) => !removed.has(id));
    updatePlaylistRemoteSongIDs(state, playlist);
    markPlaylistDirty(playlist);
    playlistMembershipChanged = true;
  });
  state.tracks = state.tracks.filter((track) => !removed.has(track.id));
  state.favorites = state.favorites.filter((id) => !removed.has(id));
  state.playlists.filter((playlist) => playlist.isSystem)
    .forEach((playlist) => { playlist.trackIDs = playlist.trackIDs.filter((id) => !removed.has(id)); });
  activePlaybackQueueIDs = activePlaybackQueueIDs.filter((id) => !removed.has(id));
  activePlaybackSourceQueueIDs = activePlaybackSourceQueueIDs.filter((id) => !removed.has(id));
  state.playbackQueueIDs = [...activePlaybackQueueIDs];
  state.playbackSourceQueueIDs = [...activePlaybackSourceQueueIDs];
  if (removed.has(currentID)) {
    currentID = null;
    state.currentTrackID = null;
    state.position = 0;
  } else if (releasedCurrentTrack?.track) {
    state.position = releasedCurrentTrack.position;
    pendingRestorePosition = releasedCurrentTrack.position;
    setAudioSource(releasedCurrentTrack.track);
    audio.volume = playbackGainForVolume(state.volume);
    audio.playbackRate = Number($("#speed").value) || 1;
    if (releasedCurrentTrack.wasPlaying) void requestPlayback();
  }
  selectedStorageIDs = new Set(failed.map(({ track }) => track.id));
  if (removed.size) {
    await persist();
    if (playlistMembershipChanged) schedulePlaylistSync();
  }
  render();
  updateChrome();
  if (failed.length) {
    const names = failed.slice(0, 3).map(({ track }) => track.title).join(", ");
    showNotice(`Could not remove ${names}${failed.length > 3 ? ` and ${failed.length - 3} more` : ""}. The files remain in your library.`);
  }
}

function renderStorage() {
  updateTopSearch();
  const tracks = storageTracks();
  const visibleTracks = tracksForActiveProfile(state);
  const localTracks = visibleTracks.filter((track) => physicalStorageClassForTrack(track) === "files" && track.available !== false);
  const remoteTracks = visibleTracks.filter((track) => physicalStorageClassForTrack(track) === "downloads" && track.available !== false);
  const localBytes = localTracks.reduce((sum, track) => sum + (track.size || 0), 0);
  const remoteBytes = remoteTracks.reduce((sum, track) => sum + (track.size || 0), 0);
  const total = Math.max(localBytes + remoteBytes, 1);
  const localDegrees = Math.round(localBytes / total * 360);
  const storageHasQuery = Boolean(storageQuery.trim());
  const storageEmptyTitle = storageHasQuery ? "No matching songs" : storageScope === "downloads" ? "No server downloads yet" : storageScope === "files" ? "No imported files yet" : "No songs stored yet";
  const storageEmptyHelp = storageHasQuery ? "Try another search." : storageScope === "downloads" ? "Download songs from Music Server to keep them on this device." : "Import audio files to add them to this device.";
  content.innerHTML = `<div class="page storage-page"><div class="page-title-row"><div><span class="eyebrow">ON THIS DEVICE</span><h1>Song Storage</h1></div><div class="page-title-actions"><div class="storage-import-control" id="storageImportControl"><button class="primary storage-import-trigger" id="storageImportMenuButton" type="button" aria-haspopup="menu" aria-expanded="false" aria-controls="storageImportMenu"><span class="button-icon" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M12 3v11m0 0 4-4m-4 4-4-4M5 16v3h14v-3"/></svg></span><span>Import</span><svg class="storage-import-chevron" viewBox="0 0 16 16" aria-hidden="true"><path d="m4 6 4 4 4-4"/></svg></button><div class="storage-import-menu" id="storageImportMenu" role="menu" aria-label="Choose an import type" hidden>${localImportAvailable ? '<button class="storage-import-option" type="button" role="menuitem" data-storage-import="link"><span class="storage-import-option-icon" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M14 4h6v6M20 4l-9 9M10 6H6a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-4"/></svg></span><span><strong>Import from link</strong><small>Paste a link or search music</small></span></button>' : ""}<button class="storage-import-option" type="button" role="menuitem" data-storage-import="files"><span class="storage-import-option-icon" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M4 7.5h6l2-2h8v13H4zM12 10v6m-3-3h6"/></svg></span><span><strong>Import files</strong><small>Choose audio from this device</small></span></button></div></div><button class="secondary" id="storageEdit" ${!storageEditing && !tracks.length ? "disabled" : ""}>${storageEditing ? "Done" : "Edit"}</button></div></div>
    <div class="storage-summary" id="storageSummary"><div class="storage-ring" id="storageRing" style="--local:${localDegrees}deg"><span>♪</span></div><div class="storage-stat"><small>Local audio</small><strong id="storageLocalBytes">${formatBytes(localBytes)}</strong><span>${localTracks.length} available library ${localTracks.length === 1 ? "file" : "files"}</span></div><div class="storage-stat"><small>Server downloads</small><strong id="storageRemoteBytes">${formatBytes(remoteBytes)}</strong><span>${remoteTracks.length} available library ${remoteTracks.length === 1 ? "file" : "files"}</span></div><div class="storage-stat"><small>Available</small><strong id="storageAvailable">Calculating…</strong><span id="storageFreePercent">Disk space</span></div></div>
    <div class="segmented storage-tabs" role="group" aria-label="Storage scope"><button class="${storageScope === "songs" ? "active" : ""}" data-storage-scope="songs" aria-pressed="${storageScope === "songs"}">Songs</button><button class="${storageScope === "downloads" ? "active" : ""}" data-storage-scope="downloads" aria-pressed="${storageScope === "downloads"}">Downloads</button><button class="${storageScope === "files" ? "active" : ""}" data-storage-scope="files" aria-pressed="${storageScope === "files"}">Files</button></div>
    ${storageEditing ? `<div class="selection-bar"><span>${selectedStorageIDs.size} selected</span><button class="danger" id="deleteSelectedStorage" ${selectedStorageIDs.size ? "" : "disabled"}>Delete selected</button></div>` : ""}
    <div class="storage-section-heading"><strong>${storageScope === "downloads" ? "DOWNLOADED FROM SERVER" : storageScope === "files" ? "IMPORTED ON THIS PC" : "ALL SONGS"}</strong><span>${tracks.length} songs</span></div>
    <div class="storage-list redesigned">${tracks.map((track) => {
      const unavailable = track.available === false || track.missing;
      return `<div class="storage-row ${storageEditing ? "selecting" : ""}${unavailable ? " unavailable" : ""}" data-storage-track="${escapeHTML(track.id)}" tabindex="0" aria-keyshortcuts="Enter Space Shift+F10" aria-disabled="${unavailable}"><button class="storage-select ${selectedStorageIDs.has(track.id) ? "selected" : ""}" data-storage-select="${escapeHTML(track.id)}" aria-label="${selectedStorageIDs.has(track.id) ? "Deselect" : "Select"} ${escapeHTML(track.title || "song")}" aria-pressed="${selectedStorageIDs.has(track.id)}" ${storageEditing ? "" : "hidden"}>${selectedStorageIDs.has(track.id) ? "✓" : "○"}</button>${artwork(track)}<span class="track-details"><strong>${escapeHTML(track.title)}</strong><small>${unavailable ? "File unavailable on this device" : `${escapeHTML(track.artist || "Unknown Artist")} • ${escapeHTML(displayAlbum(track))}`}</small></span><span class="storage-size">${unavailable ? "Missing" : formatBytes(track.size)}</span><button class="row-menu" data-storage-menu="${escapeHTML(track.id)}" title="More options" aria-label="More options for ${escapeHTML(track.title || "song")}">•••</button></div>`;
    }).join("") || `<div class="empty"><b>${storageEmptyTitle}</b><span>${storageEmptyHelp}</span></div>`}</div></div>`;
  const importControl = $("#storageImportControl");
  const importButton = $("#storageImportMenuButton");
  const importMenu = $("#storageImportMenu");
  const importOptions = [...importMenu.querySelectorAll('[role="menuitem"]')];
  let outsideImportPointerHandler = null;
  const closeImportMenu = ({ restoreFocus = false } = {}) => {
    importMenu.hidden = true;
    importButton.setAttribute("aria-expanded", "false");
    importControl.classList.remove("open");
    if (outsideImportPointerHandler) {
      document.removeEventListener("pointerdown", outsideImportPointerHandler);
      outsideImportPointerHandler = null;
    }
    if (restoreFocus) importButton.focus();
  };
  const openImportMenu = () => {
    importMenu.hidden = false;
    importButton.setAttribute("aria-expanded", "true");
    importControl.classList.add("open");
    requestAnimationFrame(() => importOptions[0]?.focus());
    outsideImportPointerHandler = (event) => {
      if (!importControl.contains(event.target)) closeImportMenu();
    };
    document.addEventListener("pointerdown", outsideImportPointerHandler);
  };
  importButton.onclick = () => importMenu.hidden ? openImportMenu() : closeImportMenu();
  importMenu.onkeydown = (event) => {
    const currentIndex = importOptions.indexOf(document.activeElement);
    if (event.key === "Escape") {
      event.preventDefault();
      closeImportMenu({ restoreFocus: true });
    } else if (["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) {
      event.preventDefault();
      const nextIndex = event.key === "Home" ? 0
        : event.key === "End" ? importOptions.length - 1
          : (currentIndex + (event.key === "ArrowDown" ? 1 : -1) + importOptions.length) % importOptions.length;
      importOptions[nextIndex]?.focus();
    }
  };
  importOptions.forEach((button) => button.onclick = () => {
    const type = button.dataset.storageImport;
    closeImportMenu();
    if (type === "link") openLocalImport();
    else importAudio();
  });
  $("#storageEdit").onclick = () => { storageEditing = !storageEditing; if (!storageEditing) selectedStorageIDs.clear(); renderStorage(); };
  document.querySelectorAll("[data-storage-scope]").forEach((button) => button.onclick = () => {
    storageScope = button.dataset.storageScope;
    storageEditing = false;
    selectedStorageIDs.clear();
    renderStorage();
  });
  document.querySelectorAll("[data-storage-select]").forEach((button) => button.onclick = () => { selectedStorageIDs.has(button.dataset.storageSelect) ? selectedStorageIDs.delete(button.dataset.storageSelect) : selectedStorageIDs.add(button.dataset.storageSelect); renderStorage(); });
  if ($("#deleteSelectedStorage")) $("#deleteSelectedStorage").onclick = async () => {
    if (selectedStorageIDs.size && confirm(`Remove ${selectedStorageIDs.size} selected song${selectedStorageIDs.size === 1 ? "" : "s"} from this device?`)) await deleteStoredTracks([...selectedStorageIDs]);
  };
  document.querySelectorAll("[data-storage-track]").forEach((row) => {
    const openMenu = (event) => openTrackContextMenu(event, row.dataset.storageTrack, { source: "storage", playbackTracks: tracks, playlistID: null });
    row.oncontextmenu = openMenu;
    row.onkeydown = (event) => {
      if (event.target !== row) return;
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        if (storageEditing) {
          selectedStorageIDs.has(row.dataset.storageTrack)
            ? selectedStorageIDs.delete(row.dataset.storageTrack)
            : selectedStorageIDs.add(row.dataset.storageTrack);
          renderStorage();
        } else {
          play(state.tracks.find((track) => track.id === row.dataset.storageTrack), tracks, { playlistID: null });
        }
        return;
      }
      if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) {
        event.preventDefault();
        openMenu(event);
      }
    };
  });
  document.querySelectorAll("[data-storage-menu]").forEach((button) => {
    button.onclick = (event) => openTrackContextMenu(event, button.dataset.storageMenu, { source: "storage", playbackTracks: tracks, playlistID: null });
  });
  api.storageSummary().then((summary) => {
    if (section !== "storage") return;
    const local = $("#storageLocalBytes");
    const remote = $("#storageRemoteBytes");
    const ring = $("#storageRing");
    const available = $("#storageAvailable");
    const percent = $("#storageFreePercent");
    if (local) local.textContent = formatBytes(summary.localBytes);
    if (remote) remote.textContent = formatBytes(summary.remoteBytes);
    const managedBytes = Math.max(0, Number(summary.localBytes) || 0) + Math.max(0, Number(summary.remoteBytes) || 0);
    if (ring) ring.style.setProperty("--local", `${managedBytes ? Math.round((Number(summary.localBytes) || 0) / managedBytes * 360) : 0}deg`);
    if (available) available.textContent = formatBytes(summary.availableBytes);
    if (percent) percent.textContent = summary.capacityBytes ? `${Math.round(summary.availableBytes / summary.capacityBytes * 100)}% free` : "Disk space";
  }).catch((error) => {
    if (section !== "storage") return;
    const available = $("#storageAvailable");
    const percent = $("#storageFreePercent");
    if (available) available.textContent = "Unavailable";
    if (percent) percent.textContent = "Could not read disk space";
    showNotice(error.message || "Resonance could not read available disk space.");
  });
}

function serverUploadManifestFromResult(result, context, source) {
  if (result?.selectionCancelled) return null;
  const uploaded = (Array.isArray(result?.results) ? result.results : []).map((item) => ({
    retryID: item.retryID || null,
    trackID: item.trackID || null,
    filename: item.filename || null,
    title: item.title || item.filename || "Untitled song",
    artist: item.artist || null,
    status: "uploaded",
    attempts: item.attempts || 1,
    message: null,
    remoteID: item.remoteSong?.id || null,
  }));
  const failed = (Array.isArray(result?.failed) ? result.failed : []).map((item) => ({
    retryID: item.retryID || null,
    trackID: item.trackID || null,
    filename: item.filename || null,
    title: item.title || item.filename || "Untitled song",
    artist: item.artist || null,
    status: item.status === "cancelled" ? "cancelled" : "failed",
    attempts: item.attempts || 0,
    message: item.message || (item.status === "cancelled" ? "Upload cancelled." : "Upload failed."),
    remoteID: null,
  }));
  if (!uploaded.length && !failed.length) return null;
  const now = new Date().toISOString();
  return normalizeServerUploadManifest({
    id: crypto.randomUUID(),
    serverOrigin: normalizedServerOrigin(context.serverURL),
    profileID: context.profileID,
    source,
    startedAt: now,
    updatedAt: now,
    items: [...uploaded, ...failed],
  });
}

async function retainServerUploadManifest(result, context, source) {
  const manifest = serverUploadManifestFromResult(result, context, source);
  if (!manifest) return null;
  state.serverUploadManifests = [...state.serverUploadManifests, manifest].slice(-20);
  await persist({ refreshSidebar: false });
  return manifest;
}

function currentServerUploadManifests() {
  const serverOrigin = normalizedServerOrigin(state.serverURL);
  const profileID = activeProfileID();
  return state.serverUploadManifests
    .filter((manifest) => manifest.serverOrigin === serverOrigin && manifest.profileID === profileID)
    .sort((left, right) => Date.parse(right.updatedAt) - Date.parse(left.updatedAt));
}

function serverUploadManifestMarkup() {
  return currentServerUploadManifests().map((manifest) => {
    const failures = manifest.items.filter((item) => item.status !== "uploaded");
    const uploaded = manifest.items.length - failures.length;
    const retryIDs = serverUploadManifestRetryIDs(manifest);
    const label = manifest.source === "missing-downloads"
      ? "Downloaded-song upload"
      : manifest.source === "link-import" ? "Link-import upload" : "Source-link upload";
    const timestamp = new Date(manifest.updatedAt).toLocaleString();
    const summary = failures.length
      ? `${uploaded} uploaded · ${failures.length} need attention`
      : `${uploaded} uploaded · no failures`;
    return `<section class="server-upload-manifest${failures.length ? " has-failures" : " complete"}" data-server-upload-manifest="${escapeHTML(manifest.id)}" aria-label="${escapeHTML(label)} results">
      <header><span><strong>${escapeHTML(label)}</strong><small>${escapeHTML(timestamp)} · ${escapeHTML(summary)}</small></span><button type="button" class="server-upload-manifest-dismiss" data-dismiss-upload-manifest="${escapeHTML(manifest.id)}" aria-label="Dismiss ${escapeHTML(label)} results">×</button></header>
      <div class="server-upload-manifest-items">${manifest.items.map((item) => `<div class="server-upload-manifest-item ${item.status}">
        <span class="server-upload-manifest-status" aria-hidden="true">${item.status === "uploaded" ? "✓" : item.status === "cancelled" ? "‖" : "!"}</span>
        <span><strong>${escapeHTML(item.title)}</strong><small>${escapeHTML([item.artist, item.filename].filter(Boolean).join(" · ") || "Local file")}</small>${item.message ? `<em>${escapeHTML(item.message)}</em>` : ""}</span>
        <span>${item.status === "uploaded" ? "Uploaded" : item.status === "cancelled" ? "Cancelled" : `Failed after ${item.attempts || 0} attempt${item.attempts === 1 ? "" : "s"}`}</span>
      </div>`).join("")}</div>
      <footer>${retryIDs.length ? `<button type="button" class="secondary" data-retry-upload-manifest="${escapeHTML(manifest.id)}" ${serverTransferActive ? "disabled" : ""}>Retry ${retryIDs.length} failed</button>` : ""}<span>${failures.length ? "Source files are kept; no cleanup is available until every required upload succeeds." : "All required uploads completed. Source files were not changed."}</span></footer>
    </section>`;
  }).join("");
}

async function dismissServerUploadManifest(manifestID) {
  const manifest = state.serverUploadManifests.find((item) => item.id === manifestID);
  if (!manifest) return;
  const retryIDs = serverUploadManifestRetryIDs(manifest);
  state.serverUploadManifests = state.serverUploadManifests.filter((item) => item.id !== manifestID);
  await persist({ refreshSidebar: false });
  if (retryIDs.length) {
    await api.discardServerUploadRetries({
      baseURL: state.serverURL,
      profileID: activeProfileID(),
      retryIDs,
    }).catch(() => undefined);
  }
  if (section === "server") renderServer();
}

async function retryServerUploadManifest(manifestID) {
  if (serverUploadBlockedByActivity({ transferActive: serverTransferActive || Boolean(serverContextReservation) })) return;
  try {
    await saveServerForm();
  } catch (error) {
    showNotice(friendlyIPCError(error, "Server settings could not be saved before retrying."));
    return;
  }
  const configurationError = serverUploadConfigurationError({ serverURL: state.serverURL, adminToken: serverAdminToken });
  if (configurationError) {
    showNotice(configurationError);
    return;
  }
  const manifest = state.serverUploadManifests.find((item) => item.id === manifestID);
  const retryIDs = serverUploadManifestRetryIDs(manifest);
  if (!manifest || !retryIDs.length) return;
  const context = currentServerUploadContext();
  if (manifest.serverOrigin !== normalizedServerOrigin(context.serverURL) || manifest.profileID !== context.profileID) {
    showNotice("Switch back to the server and profile that created these upload results before retrying.");
    return;
  }
  for (const item of manifest.items) {
    if (!item.trackID || item.status === "uploaded") continue;
    const track = state.tracks.find((candidate) => candidate.id === item.trackID);
    if (track) {
      const conflict = remoteAssociationConflictMessage(track, {
        serverURL: context.serverURL,
        profileID: context.profileID,
      });
      if (conflict) {
        showNotice(conflict);
        return;
      }
    }
  }
  serverTransferCancelRequested = false;
  updateServerTransfer({ direction: "upload", currentFile: "Retrying failed uploads…", completed: 0, total: retryIDs.length });
  try {
    const result = await api.uploadServer({
      baseURL: context.serverURL,
      adminToken: context.adminToken,
      profileID: context.profileID,
      retryIDs,
    });
    if (!serverUploadContextIsCurrent(context)) return;
    rememberUploadedServerSongs(result.results);
    const uploadedByID = new Map((result.results || []).map((item) => [item.retryID, item]));
    const failedByID = new Map((result.failed || []).map((item) => [item.retryID, item]));
    manifest.items = manifest.items.map((item) => {
      const uploaded = uploadedByID.get(item.retryID);
      if (uploaded) return {
        ...item,
        status: "uploaded",
        attempts: uploaded.attempts || item.attempts,
        message: null,
        remoteID: uploaded.remoteSong?.id || item.remoteID || null,
      };
      const failure = failedByID.get(item.retryID);
      if (failure) return {
        ...item,
        status: failure.status === "cancelled" ? "cancelled" : "failed",
        attempts: failure.attempts || 0,
        message: failure.message || "Upload failed.",
      };
      return item;
    });
    manifest.updatedAt = new Date().toISOString();
    state.serverUploadManifests = state.serverUploadManifests
      .map((item) => item.id === manifest.id ? normalizeServerUploadManifest(manifest) : item)
      .filter(Boolean);
    for (const uploaded of result.results || []) {
      if (!uploaded.trackID) continue;
      reconcileUploadedTrack(state, uploaded.trackID, uploaded.remoteSong, {
        serverURL: context.serverURL,
        profileID: context.profileID,
      });
    }
    await persist();
    const failureNotice = formatServerUploadFailureNotice(result.failed);
    if (failureNotice) showNotice(failureNotice);
    else if (!result.cancelled) showNotice(`Retried ${result.uploaded} upload${result.uploaded === 1 ? "" : "s"} successfully.`, "status");
    if ((result.results || []).length) {
      schedulePlaylistSync();
      scheduleServerCatalogRefresh(context);
    }
  } catch (error) {
    if (!serverUploadContextIsCurrent(context)) return;
    showNotice(friendlyIPCError(error, "Failed uploads could not be retried."));
  } finally {
    hideServerTransfer("server");
    serverTransferCancelRequested = false;
    if (section === "server") renderServer();
  }
}

function renderServer() {
  updateTopSearch();
  const transferModes = currentServerTransferModes();
  const offlineDownloadAvailable = transferModes.downloadMode === "verified_file_cache";
  const uploadAvailable = Boolean(transferModes.uploadMode);
  const fileUploadSelected = transferModes.uploadMode === "local_file";
  const downloaded = serverCatalog.filter((song) => activeRemoteTrack(song.id)).length;
  const filteredCount = filteredServerCatalog().length;
  const playlistCount = state.playlists.filter((playlist) => !playlist.isSystem).length;
  const connected = serverConnected;
  const showConnectionDetail = !connected;
  const selectLabel = serverSelecting ? "Cancel song selection" : "Choose songs to download";
  const downloadLabel = !offlineDownloadAvailable
    ? "Stream-only mode is enabled; choose a song row to play it without saving it"
    : serverSelecting
    ? selectedRemoteIDs.size
      ? `Download ${selectedRemoteIDs.size} selected song${selectedRemoteIDs.size === 1 ? "" : "s"}`
      : "Select songs to download"
    : "Download all songs";
  const filtered = Boolean(serverQuery.trim()) || serverScope !== "all";
  const resultSummary = filtered ? `Showing ${filteredCount} of ${serverCatalog.length} tracks` : "All tracks";
  content.innerHTML = `<div class="page server-page">
    <div class="server-heading"><h1>Music Server</h1><div class="server-status-line">
      <span id="serverStatus" class="connection-pill ${connected ? "connected" : ""}">● ${escapeHTML(connected ? "Connected" : serverConnectInFlight ? "Connecting" : "Offline")}</span>
      <span class="server-connection-detail" role="status" aria-live="polite" ${showConnectionDetail ? "" : "hidden"}>${escapeHTML(serverConnectionText)}</span>
      <button class="server-url" id="serverSettings" title="Edit server connection"><span>${escapeHTML(state.serverURL || "Add a server connection")}</span><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m4 20 4.5-1 10-10-3.5-3.5-10 10zM13.5 7l3.5 3.5"/></svg></button>
      <span class="server-dot">•</span><span class="server-inline-metric purple">${serverSongIcon}<strong id="serverSongCount">${serverCatalog.length}</strong><span>songs</span></span>
      <span class="server-dot">•</span><span class="server-inline-metric violet">${serverPlaylistMetricIcon}<strong>${playlistCount}</strong><span>playlists</span></span>
      <span class="server-dot">•</span><span class="server-inline-metric green">${serverDeviceIcon}<strong>${downloaded}</strong><span>on device</span></span>
    </div></div>
    ${serverUploadManifestMarkup()}
    <div class="server-library-bar"><div><strong>${resultSummary}</strong><small class="server-transfer-mode-summary">${escapeHTML(`${serverUploadModeOptions[transferModes.uploadMode] || "Uploads disabled"} · ${serverDownloadModeOptions[transferModes.downloadMode] || "Downloads disabled"}`)}</small></div><div class="server-actions">
      <button id="uploadMissingDownloads" title="${fileUploadSelected ? "Upload downloaded songs missing from the server" : "Available only in Local files upload mode"}" aria-label="Upload downloaded songs missing from the server" ${fileUploadSelected ? "" : "disabled"}>${serverUploadMissingIcon}</button>
      <button id="uploadServer" title="${escapeHTML(uploadAvailable ? serverUploadModeOptions[transferModes.uploadMode] : "Uploads are disabled")}" aria-label="${escapeHTML(uploadAvailable ? serverUploadModeOptions[transferModes.uploadMode] : "Uploads are disabled")}" ${uploadAvailable ? "" : "disabled"}>${serverUploadIcon}</button>
      <button id="syncAll" title="${downloadLabel}" aria-label="${downloadLabel}" ${!offlineDownloadAvailable || (serverSelecting && !selectedRemoteIDs.size) ? "disabled" : ""}>${serverDownloadIcon}</button>
      <button id="syncSelected" class="${serverSelecting ? "active" : ""}" title="${offlineDownloadAvailable ? selectLabel : downloadLabel}" aria-label="${offlineDownloadAvailable ? selectLabel : downloadLabel}" aria-pressed="${serverSelecting}" ${offlineDownloadAvailable ? "" : "disabled"}>${serverSelecting ? `<b>${selectedRemoteIDs.size}</b>` : serverSelectIcon}</button>
      <button id="syncServerPlaylists" title="Sync playlists" aria-label="Sync playlists">${serverPlaylistIcon}</button>
    </div></div>
    <div class="server-table-head ${serverSelecting ? "selecting" : ""}">${serverSelecting ? "<span></span>" : ""}<span></span><span>TITLE</span><span>ARTIST</span><span>ALBUM</span><span>DURATION</span><span></span></div>
    <div id="remoteSongs" class="remote-list redesigned server-library">${filteredCount ? remoteRows() : `<div class="empty"><b>${serverCatalog.length ? "No matching songs" : "No server songs"}</b><span>${serverConnectInFlight ? "Connecting to your server…" : serverCatalog.length ? "Try another search or filter." : "Open connection settings to connect."}</span></div>`}</div>
  </div>`;
  $("#serverSettings").onclick = openServerSettings;
  $("#syncSelected").onclick = () => {
    if (!serverSelecting) {
      serverSelecting = true;
    } else {
      serverSelecting = false;
    }
    selectedRemoteIDs.clear();
    renderServer();
  };
  $("#syncAll").onclick = () => serverAction(serverSelecting ? "selected" : "all");
  $("#uploadMissingDownloads").onclick = uploadMissingDownloadedSongs;
  $("#uploadServer").onclick = uploadServerSongs;
  $("#syncServerPlaylists").onclick = () => syncPlaylistsNow();
  bindServerArtworkLoadStates();
  bindRemoteRows();
  document.querySelectorAll("[data-retry-upload-manifest]").forEach((button) => {
    button.onclick = () => retryServerUploadManifest(button.dataset.retryUploadManifest);
  });
  document.querySelectorAll("[data-dismiss-upload-manifest]").forEach((button) => {
    button.onclick = () => dismissServerUploadManifest(button.dataset.dismissUploadManifest);
  });
  if (!serverAutoAttempted && !serverConnectInFlight && state.serverURL && serverToken) {
    serverAutoAttempted = true;
    queueMicrotask(() => { if (section === "server") serverAction("catalog"); });
  }
}

function filteredServerCatalog() {
  const query = serverQuery.toLocaleLowerCase();
  return serverCatalog.filter((song) => {
    const onDevice = Boolean(activeRemoteTrack(song.id));
    if (serverScope === "device" && !onDevice) return false;
    if (serverScope === "available" && onDevice) return false;
    return `${song.title || song.name || ""} ${song.artist || ""} ${song.album || ""}`.toLocaleLowerCase().includes(query);
  }).sort((left, right) => {
    if (serverSort === "size") return (right.size || 0) - (left.size || 0);
    if (serverSort === "artist") return String(left.artist || "").localeCompare(String(right.artist || ""));
    return String(left.title || left.name || "").localeCompare(String(right.title || right.name || ""));
  });
}

function remoteRows() {
  return filteredServerCatalog().map((song) => {
    const onDevice = Boolean(activeRemoteTrack(song.id));
    const selected = selectedRemoteIDs.has(song.id);
    const duration = Number(song.duration) > 0 ? formatTime(Number(song.duration)) : "—";
    return `<div class="remote-row ${serverSelecting ? "selecting" : ""} ${selected ? "selected" : ""}" data-remote-row="${escapeHTML(song.id)}" tabindex="0" aria-keyshortcuts="Enter Space Shift+F10">
      <button class="remote-check ${selected ? "selected" : ""}" data-select-remote="${escapeHTML(song.id)}" ${serverSelecting ? "" : "hidden"} aria-label="${selected ? "Deselect" : "Select"} ${escapeHTML(song.title || song.name)}">${selected ? "✓" : ""}</button>
      ${artwork(song, { animateLoading: true })}
      <span class="server-song-title"><strong>${escapeHTML(song.title || song.name)}</strong>${onDevice ? '<small>On device</small>' : serverSongRequiresDownload(song) && currentServerTransferModes().downloadMode === "stream_only" ? '<small>Video · download required</small>' : ""}</span>
      <span class="server-cell">${escapeHTML(song.artist || "Unknown Artist")}</span>
      <span class="server-cell server-album">${escapeHTML(displayAlbum(song))}</span>
      <span class="server-cell server-duration">${duration}</span>
      <button class="row-menu" data-remote-menu="${escapeHTML(song.id)}" title="More options" aria-label="More options for ${escapeHTML(song.title || song.name)}">•••</button>
    </div>`;
  }).join("");
}

function bindRemoteRows() {
  document.querySelectorAll("[data-select-remote]").forEach((button) => button.onclick = () => { selectedRemoteIDs.has(button.dataset.selectRemote) ? selectedRemoteIDs.delete(button.dataset.selectRemote) : selectedRemoteIDs.add(button.dataset.selectRemote); renderServer(); });
  document.querySelectorAll("[data-remote-row]").forEach((row) => {
    const activate = () => {
      const id = row.dataset.remoteRow;
      if (serverSelecting) {
        selectedRemoteIDs.has(id) ? selectedRemoteIDs.delete(id) : selectedRemoteIDs.add(id);
        renderServer();
        return;
      }
      const song = serverCatalog.find((candidate) => candidate.id === id);
      const localTrack = playableActiveRemoteTrack(id);
      if (localTrack) play(localTrack);
      else if (currentServerTransferModes().downloadMode !== "verified_file_cache") {
        void playRemoteStream(song);
      } else {
        serverSelecting = true;
        selectedRemoteIDs = new Set([id]);
        renderServer();
      }
    };
    row.onclick = (event) => {
      if (event.target.closest("button")) return;
      activate();
    };
    row.oncontextmenu = (event) => openServerTrackContextMenu(event, row.dataset.remoteRow);
    row.onkeydown = (event) => {
      if (event.target !== row) return;
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        activate();
        return;
      }
      if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) {
        event.preventDefault();
        openServerTrackContextMenu(event, row.dataset.remoteRow);
      }
    };
  });
  document.querySelectorAll("[data-remote-menu]").forEach((button) => {
    button.onclick = (event) => openServerTrackContextMenu(event, button.dataset.remoteMenu);
  });
}

function renderProfileOptions(selectedID = activeProfileID()) {
  const select = $("#syncProfile");
  if (!select) return;
  setCustomSelectOptions(select, state.syncProfiles.map((profile) => ({
    value: profile.id,
    label: profile.name,
  })), state.syncProfiles.some((profile) => profile.id === selectedID) ? selectedID : "default");
}

async function refreshProfiles() {
  const url = $("#serverURL")?.value.trim() || state.serverURL;
  const token = serverToken;
  if (!url || !token) return;
  if (accountSession?.profileID) {
    const profile = {
      id: accountSession.profileID,
      name: safeAccountDisplayName(accountSession),
      is_default: true,
    };
    state.syncProfiles = [profile];
    await activateProfile(profile.id, accountSession.baseURL);
    renderProfileOptions(profile.id);
    return;
  }
  const response = await api.fetchProfiles({ baseURL: url, token });
  state.syncProfiles = response.profiles || [];
  const resolution = resolveSyncProfile(state.syncProfiles, activeProfileID(), response.default_profile_id);
  if (resolution.profile && resolution.profile.id !== activeProfileID()) {
    await activateProfile(resolution.profile.id);
  }
  renderProfileOptions(resolution.profile?.id || activeProfileID());
}

async function activateProfile(profileID, serverURL = state.serverURL) {
  if (!profileID) return;
  const targetServerKey = normalizedServerKey(serverURL);
  if (profileID === activeProfileID() && targetServerKey === normalizedServerKey(state.serverURL)) return;
  ensureServerContextCanChange();
  releaseActiveServerStream({ stopPlayback: true });
  const resumeListeningSession = checkpointListeningSessionForContextChange();
  storeActiveProfileState(state);
  restoreProfileState(state, profileID, serverURL);
  profileGeneration += 1;
  clientConfigRequestGeneration += 1;
  clientConfig = SAFE_CLIENT_CONFIG;
  if (playlistSyncInFlight) playlistSyncPending = true;
  if (serverConnectInFlight) serverConnectPending = true;
  serverConnected = false;
  replaceServerCatalog([]);
  selectedRemoteIDs.clear();
  selectedPlaylistID = null;
  const visibleTrackIDs = new Set(tracksForActiveProfile(state).map((track) => track.id));
  activePlaybackQueueIDs = activePlaybackQueueIDs.filter((id) => visibleTrackIDs.has(id));
  activePlaybackSourceQueueIDs = activePlaybackSourceQueueIDs.filter((id) => visibleTrackIDs.has(id));
  state.playbackQueueIDs = [...activePlaybackQueueIDs];
  state.playbackSourceQueueIDs = [...activePlaybackSourceQueueIDs];
  if (currentID && !visibleTrackIDs.has(currentID)) {
    audio.pause();
    audio.removeAttribute("src");
    currentID = null;
    state.currentTrackID = null;
    state.position = 0;
  } else if (currentID) {
    const range = activeClipRange();
    if (range && (audio.currentTime < range.startSeconds || audio.currentTime >= range.endSeconds)) {
      audio.currentTime = range.startSeconds;
      state.position = range.startSeconds;
    }
  }
  await persist();
  if (resumeListeningSession && currentID && playbackIsActive()) beginListeningSession();
}

function openServerSettings() {
  openSettings("server");
}

async function saveServerForm() {
  ensureServerContextCanChange();
  const settingsOpen = Boolean($("#settingsDialog")?.open && settingsPanel === "server" && $("#serverSettingsForm"));
  const nextServerURL = settingsOpen ? $("#serverURL").value.trim() : state.serverURL;
  const nextProfileID = accountSession?.profileID
    || (settingsOpen ? ($("#syncProfile")?.value || activeProfileID()) : activeProfileID());
  await activateProfile(nextProfileID, nextServerURL);
  await refreshClientConfig({ force: true });
  await persist();
  updateProfileControl();
  schedulePlaylistSync();
  scheduleListeningHistorySync();
}

async function applyAccountSession(nextSession, error = null) {
  const previousToken = serverToken;
  const previousEmail = accountSession?.email || null;
  accountSession = nextSession || null;
  if ((accountSession?.email || null) !== previousEmail) isAccountEmailRevealed = false;
  serverToken = String(accountSession?.accessToken || "").trim();
  serverAdminToken = accountSession ? serverToken : "";
  const migratedLocalContext = accountSession?.profileID && accountSession?.migratedProfileID
    ? migrateProfileContext(
        state,
        accountSession.baseURL,
        accountSession.migratedProfileID,
        accountSession.profileID,
      )
    : false;
  if (previousToken !== serverToken) {
    releaseActiveServerStream({ stopPlayback: true });
    serverConnected = false;
    replaceServerCatalog([]);
    selectedRemoteIDs.clear();
  }
  if (error) serverConnectionText = error;
  else if (accountSession) serverConnectionText = "Signed in with Clerk";
  else serverConnectionText = "Not signed in";
  if ($("#settingsDialog")?.open && settingsPanel === "server") renderSettings();
  if (accountSession?.profileID) {
    state.serverURL = accountSession.baseURL;
    state.syncProfiles = [{
      id: accountSession.profileID,
      name: safeAccountDisplayName(accountSession),
      is_default: true,
    }];
    await activateProfile(accountSession.profileID, accountSession.baseURL);
  }
  if (migratedLocalContext) await persist();
  updateProfileControlView({ refreshPicture: false });
}

function renderSettings() {
  const profile = activeProfile();
  state.appPreferences = normalizedAppPreferences(state.appPreferences);
  const preferences = state.appPreferences;
  const keybindRows = Object.entries(settingsKeybindActions).map(([action, metadata]) => {
    const recording = settingsRecordingAction === action;
    return `<div class="settings-row settings-keybind-row">
      <span class="settings-row-icon" aria-hidden="true">${settingsIcons.keybinds}</span>
      <span class="settings-row-copy"><strong>${metadata.label}</strong><small>${metadata.description}</small></span>
      <button class="settings-keybind${recording ? " recording" : ""}" type="button" data-keybind-action="${action}" aria-label="Change ${metadata.label} keybind"><kbd>${recording ? "Press keys…" : escapeHTML(preferences.keybinds[action])}</kbd></button>
    </div>`;
  }).join("");
  const settingsRoot = $("#settingsDialogContent");
  disposeCustomSelects(settingsRoot);
  settingsRoot.innerHTML = `<div class="settings-heading"><div><span class="eyebrow">RESONANCE</span><h1 id="settingsDialogTitle">Settings</h1><p>Manage how Resonance behaves on this Windows device.</p></div><button id="closeSettings" class="history-close" type="button" aria-label="Close settings">×</button></div>
    <div class="settings-shell">
      <nav class="settings-nav" aria-label="Settings sections">
        <button class="${settingsPanel === "general" ? "active" : ""}" type="button" data-settings-panel="general" aria-current="${settingsPanel === "general" ? "page" : "false"}">${settingsIcons.general}<span>General</span></button>
        <button class="${settingsPanel === "server" ? "active" : ""}" type="button" data-settings-panel="server" aria-current="${settingsPanel === "server" ? "page" : "false"}">${settingsIcons.server}<span>Server</span></button>
        <button class="${settingsPanel === "keybinds" ? "active" : ""}" type="button" data-settings-panel="keybinds" aria-current="${settingsPanel === "keybinds" ? "page" : "false"}">${settingsIcons.keybinds}<span>Keybinds</span></button>
      </nav>
      <div class="settings-content">
        <section class="settings-panel" data-settings-content="general" ${settingsPanel === "general" ? "" : "hidden"}>
          <div class="settings-section-heading"><span>WINDOWS</span><p>Control desktop behavior and connected services.</p></div>
          <div class="settings-grid">
            <div class="settings-group">
              <label class="settings-row" for="settingsRunInBackground">
                <span class="settings-row-icon" aria-hidden="true">${settingsIcons.background}</span>
                <span class="settings-row-copy"><strong>Running in the background</strong><small>Keep playback active in the system tray when the window closes.</small></span>
                <span class="settings-toggle"><input id="settingsRunInBackground" type="checkbox" ${preferences.runInBackground ? "checked" : ""}><span aria-hidden="true"></span></span>
              </label>
              <label class="settings-row" for="settingsDiscordPresence">
                <span class="settings-row-icon discord" aria-hidden="true">${settingsIcons.discord}</span>
                <span class="settings-row-copy"><strong>Discord Rich Presence</strong><small id="settingsDiscordStatus">${escapeHTML(discordPresenceStatus.message || "Show Resonance playback on your signed-in Discord profile.")}</small></span>
                <span class="settings-toggle"><input id="settingsDiscordPresence" type="checkbox" ${preferences.discordRichPresence && discordPresenceStatus.applicationConfigured ? "checked" : ""} ${discordPresenceStatus.applicationConfigured ? "" : "disabled"}><span aria-hidden="true"></span></span>
              </label>
            </div>
            <div class="settings-section-heading compact"><span>APP</span><p>Existing Resonance connection and update tools.</p></div>
            <div class="settings-group">
              <div class="settings-row">
                <span class="settings-row-icon" aria-hidden="true">${serverDeviceIcon}</span>
                <span class="settings-row-copy"><strong>Music Server</strong><small>${serverConnected ? "Connected" : "Not connected"} · ${escapeHTML(profile.name || "Default")} · ${escapeHTML(state.serverURL || "No server configured")}</small></span>
                <button id="settingsServer" class="settings-row-action" type="button">Configure</button>
              </div>
              <div class="settings-row">
                <span class="settings-row-icon" aria-hidden="true">${settingsIcons.update}</span>
                <span class="settings-row-copy"><strong>Updates</strong><small id="settingsUpdateStatus">${escapeHTML($("#updateStatus").textContent || "Automatic in-app updates")}</small></span>
                <button id="settingsCheckUpdates" class="settings-row-action" type="button">Check now</button>
              </div>
            </div>
          </div>
        </section>
        <section class="settings-panel" data-settings-content="server" ${settingsPanel === "server" ? "" : "hidden"}>
          <form id="serverSettingsForm" class="settings-server-form">
            <div class="settings-panel-title"><div><span class="eyebrow">ACCOUNT</span><h2>Music Server</h2><p>Clerk securely handles email, Google, Apple, and Discord sign-in for Resonance.</p></div></div>
            <div class="settings-server-card">
              <label class="settings-server-field settings-server-field-wide" for="serverURL"><span>Server URL</span><input id="serverURL" autocomplete="url" placeholder="https://music.example.com" required></label>
              <div class="settings-account-card settings-server-field-wide">
                ${accountSession
                  ? `<div><strong>${escapeHTML(safeAccountDisplayName(accountSession))}</strong><small><button id="settingsAccountEmail" class="email-disclosure" type="button" aria-label="${isAccountEmailRevealed ? "Hide" : "Reveal"} email address">${escapeHTML(displayedAccountEmail())}</button> · ${accountSession.role === "admin" ? "Administrator" : "Member"}</small></div><button id="signOutAccount" class="secondary" type="button">Sign out</button>`
                  : `<div><strong>${serverToken ? "Legacy connection" : "Sign in to Resonance"}</strong><small>${serverToken ? "Sign in to finish upgrading this device." : "Use email, Google, Apple, or Discord in your web browser."}</small></div><div class="settings-auth-grid"><button class="secondary" type="button" data-auth-provider="clerk">Sign in or create account</button></div>`}
              </div>
            </div>
            <div class="settings-server-actions">
              <span id="serverSettingsStatus" role="status">${escapeHTML(serverConnectionText || "Not connected")}</span>
              <button id="saveServerSettings" class="primary" type="submit">Save & connect</button>
            </div>
          </form>
        </section>
        <section class="settings-panel" data-settings-content="keybinds" ${settingsPanel === "keybinds" ? "" : "hidden"}>
          <div class="settings-panel-title"><div><span class="eyebrow">PLAYBACK</span><h2>Keybinds</h2><p>Choose a shortcut, then press the new key combination. These work while Resonance is focused.</p></div><button id="resetSettingsKeybinds" class="settings-row-action" type="button">Reset defaults</button></div>
          <div class="settings-group settings-keybinds">${keybindRows}</div>
        </section>
      </div>
    </div>
    <footer class="settings-footer"><button id="doneSettings" class="primary" type="button">Done</button></footer>`;
  const closeSettings = () => $("#settingsDialog").close();
  $("#closeSettings").onclick = closeSettings;
  $("#doneSettings").onclick = closeSettings;
  document.querySelectorAll("[data-settings-panel]").forEach((button) => {
    button.onclick = () => {
      settingsPanel = button.dataset.settingsPanel;
      settingsRecordingAction = null;
      renderSettings();
      if (settingsPanel === "server") void refreshServerSettingsControls();
    };
  });
  const runInBackground = $("#settingsRunInBackground");
  if (runInBackground) runInBackground.onchange = () => updateAppPreference("runInBackground", runInBackground.checked);
  const discordPresence = $("#settingsDiscordPresence");
  if (discordPresence) discordPresence.onchange = async () => {
    await updateAppPreference("discordRichPresence", discordPresence.checked);
    scheduleDiscordPresenceUpdate();
  };
  document.querySelectorAll("[data-keybind-action]").forEach((button) => {
    button.onclick = () => {
      settingsRecordingAction = button.dataset.keybindAction;
      renderSettings();
      requestAnimationFrame(() => document.querySelector(`[data-keybind-action="${settingsRecordingAction}"]`)?.focus());
    };
  });
  const resetKeybinds = $("#resetSettingsKeybinds");
  if (resetKeybinds) resetKeybinds.onclick = () => {
    state.appPreferences.keybinds = normalizedAppPreferences({}).keybinds;
    settingsRecordingAction = null;
    persistInBackground({ refreshSidebar: false });
    renderSettings();
  };
  if ($("#settingsServer")) $("#settingsServer").onclick = openServerSettings;
  if ($("#settingsCheckUpdates")) $("#settingsCheckUpdates").onclick = checkForUpdates;

  if (settingsPanel === "server") bindServerSettingsControls();
}

function bindServerSettingsControls() {
  $("#serverURL").value = state.serverURL || "";
  $("#serverURL").disabled = Boolean(accountSession);
  renderProfileOptions();

  document.querySelectorAll("[data-auth-provider]").forEach((button) => {
    button.onclick = async () => {
      const status = $("#serverSettingsStatus");
      try {
        status.textContent = "Opening secure sign-in…";
        await api.signInAccount({
          baseURL: $("#serverURL").value.trim(),
          provider: button.dataset.authProvider,
          profileID: activeProfileID(),
        });
        status.textContent = "Complete sign-in in your web browser.";
      } catch (error) {
        status.textContent = error.message || "Sign-in could not be started.";
      }
    };
  });
  const signOut = $("#signOutAccount");
  if (signOut) signOut.onclick = async () => {
    await api.signOutAccount();
    await applyAccountSession(null);
  };
  const accountEmail = $("#settingsAccountEmail");
  if (accountEmail) accountEmail.onclick = () => {
    isAccountEmailRevealed = !isAccountEmailRevealed;
    renderSettings();
    updateProfileControlView({ refreshPicture: false });
  };

  $("#serverSettingsForm").onsubmit = async (event) => {
    event.preventDefault();
    serverAutoAttempted = true;
    const saveButton = $("#saveServerSettings");
    const status = $("#serverSettingsStatus");
    saveButton.disabled = true;
    status.textContent = "Saving server settings…";
    try {
      await saveServerForm();
      if (!serverToken.trim()) {
        serverConnected = false;
        replaceServerCatalog([]);
        serverConnectionText = "Server saved • sign in to connect";
        if (section === "server") renderServer();
        showNotice(serverConnectionText, "status");
      } else {
        await serverAction("catalog");
      }
      status.textContent = serverConnectionText;
    } catch (error) {
      const message = error.message || "The server settings could not be saved.";
      status.textContent = message;
      showNotice(message);
    } finally {
      saveButton.disabled = false;
    }
  };
}

async function refreshServerSettingsControls() {
  await Promise.allSettled([refreshProfiles(), refreshClientConfig()]);
}

async function updateAppPreference(key, value) {
  state.appPreferences = normalizedAppPreferences({
    ...state.appPreferences,
    [key]: value,
  });
  persistInBackground({ refreshSidebar: false });
  await api.updateAppPreferences(state.appPreferences).catch(() => undefined);
}

function openSettings(initialPanel = "general") {
  closeProfileMenu();
  settingsPanel = initialPanel;
  settingsRecordingAction = null;
  renderSettings();
  if (!$("#settingsDialog").open) $("#settingsDialog").showModal();
  if (settingsPanel === "server") void refreshServerSettingsControls();
}

function discordPresenceActivity() {
  const track = currentTrack();
  if (!track || !state.appPreferences?.discordRichPresence || !playbackIsActive()) return null;
  const media = activePlaybackMedia();
  return {
    title: track.title,
    artist: track.artist,
    album: track.album,
    playing: playbackIsActive(),
    position: Number(media?.currentTime) || state.position || 0,
    duration: currentPlaybackDuration(track),
    artworkURL: track.artworkURL || null,
  };
}

function scheduleDiscordPresenceUpdate() {
  if (discordPresenceSyncTimer) clearTimeout(discordPresenceSyncTimer);
  discordPresenceSyncTimer = setTimeout(async () => {
    discordPresenceSyncTimer = null;
    discordPresenceStatus = await api.updateDiscordPresence(discordPresenceActivity()).catch(() => discordPresenceStatus);
    const status = $("#settingsDiscordStatus");
    if (status) status.textContent = discordPresenceStatus.message || "Show Resonance playback on your signed-in Discord profile.";
  }, 80);
}

function render() {
  if (section === "library") renderLibrary();
  else if (section === "playlists") renderPlaylists();
  else if (section === "storage") renderStorage();
  else if (section === "server") renderServer();
  else renderLibrary();
  renderSidebar();
  renderQueue();
  $("#navBack").disabled = navigationIndex === 0;
  $("#navForward").disabled = navigationIndex + 1 >= navigationHistory.length;
  bindSquareArtworkImages();
}

function bindTrackRows(playbackTracks = playlistTracks()) {
  const trackTable = document.querySelector(".track-table");
  document.querySelectorAll("[data-track]").forEach((row) => {
    row.onclick = (event) => {
      if (performance.now() < suppressPlaylistRowClickUntil) {
        event.preventDefault();
        return;
      }
      if (event.target.closest("button, select, input, a")) return;
      play(state.tracks.find((track) => track.id === row.dataset.track), playbackTracks, { playlistID: selectedPlaylistID });
    };
    row.oncontextmenu = (event) => openTrackContextMenu(event, row.dataset.track, { playbackTracks, playlistID: selectedPlaylistID });
    row.onkeydown = async (event) => {
      if (event.target !== row) return;
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        play(state.tracks.find((track) => track.id === row.dataset.track), playbackTracks, { playlistID: selectedPlaylistID });
        return;
      }
      if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) {
        event.preventDefault();
        openTrackContextMenu(event, row.dataset.track, { playbackTracks, playlistID: selectedPlaylistID });
        return;
      }
      if (!event.altKey || (event.key !== "ArrowUp" && event.key !== "ArrowDown")) return;
      const playlist = state.playlists.find((item) => item.id === selectedPlaylistID && !item.isSystem);
      if (!playlist) return;
      event.preventDefault();
      const from = playlist.trackIDs.indexOf(row.dataset.track);
      const to = from + (event.key === "ArrowUp" ? -1 : 1);
      if (from < 0 || to < 0 || to >= playlist.trackIDs.length) return;
      const trackID = row.dataset.track;
      const targetID = playlist.trackIDs[to];
      await commitPlaylistTrackReorder(trackID, targetID, event.key === "ArrowDown");
      document.querySelector(`[data-track="${CSS.escape(trackID)}"]`)?.focus();
    };
    if (row.dataset.playlistDraggable === "true") {
      // Capture mouse pointers too so crossing header controls cannot strand a drag.
      row.onpointerdown = (event) => {
        if (!event.isPrimary || event.button !== 0 || event.target.closest("button, select, input, a")) return;
        clearPlaylistPointerDrag();
        playlistPointerDrag = {
          pointerID: event.pointerId,
          sourceID: row.dataset.track,
          startX: event.clientX,
          startY: event.clientY,
          active: false,
        };
        row.setPointerCapture(event.pointerId);
      };
      row.onpointermove = (event) => {
        const drag = playlistPointerDrag;
        if (!drag || drag.pointerID !== event.pointerId || drag.sourceID !== row.dataset.track) return;
        if (!drag.active && Math.hypot(event.clientX - drag.startX, event.clientY - drag.startY) < 6) return;
        if (!drag.active) {
          drag.active = true;
          startPlaylistDragPreview(row, trackTable);
        }
        event.preventDefault();
        const destination = playlistDragDestination(trackTable, event.clientY);
        updatePlaylistDragPreview(destination?.targetRow, destination?.insertAfter);
      };
      row.onpointerup = (event) => {
        const drag = playlistPointerDrag;
        if (!drag || drag.pointerID !== event.pointerId || drag.sourceID !== row.dataset.track) return;
        if (drag.active) {
          const destination = playlistDragDestination(trackTable, event.clientY);
          updatePlaylistDragPreview(destination?.targetRow, destination?.insertAfter);
        }
        const targetID = draggingPlaylistTargetID;
        const insertAfter = draggingPlaylistInsertAfter;
        clearPlaylistPointerDrag();
        if (!drag.active) return;
        event.preventDefault();
        suppressPlaylistRowClickUntil = performance.now() + 300;
        if (targetID) void commitPlaylistTrackReorder(drag.sourceID, targetID, insertAfter).catch(() => {});
      };
      row.onpointercancel = clearPlaylistPointerDrag;
      row.onlostpointercapture = () => {
        if (playlistPointerDrag?.sourceID === row.dataset.track) clearPlaylistPointerDrag();
      };
    }
  });
  document.querySelectorAll("[data-favorite]").forEach((button) => button.onclick = (event) => { event.stopPropagation(); toggleFavorite(button.dataset.favorite); });
}

let activeContextMenuReturnFocus = null;
let activeContextMenuPosition = { x: 8, y: 8 };
let activeContextMenuAlignEnd = false;

function closeTrackContextMenu({ restoreFocus = false } = {}) {
  const menu = $("#trackContextMenu");
  if (!menu) return;
  menu.hidden = true;
  menu.innerHTML = "";
  menu.onkeydown = null;
  menu.classList.remove("full-player-context");
  if (restoreFocus) activeContextMenuReturnFocus?.focus?.();
  activeContextMenuReturnFocus = null;
  activeContextMenuAlignEnd = false;
}

function beginContextMenu(event, { alignToEnd = false } = {}) {
  event.preventDefault();
  event.stopPropagation();
  closeTrackContextMenu();
  const anchor = event.currentTarget?.getBoundingClientRect?.();
  activeContextMenuReturnFocus = event.currentTarget || null;
  activeContextMenuAlignEnd = alignToEnd;
  activeContextMenuPosition = {
    x: alignToEnd ? (anchor?.right ?? 8) : Number(event.clientX) > 0 ? Number(event.clientX) : (anchor?.left ?? 8) + 24,
    y: alignToEnd ? (anchor?.bottom ?? 8) + 8 : Number(event.clientY) > 0 ? Number(event.clientY) : (anchor?.top ?? 8) + 24,
  };
}

function renderContextMenu({ title, subtitle, actions }) {
  const showHeader = arguments[0]?.showHeader === true;
  const menu = $("#trackContextMenu");
  menu.setAttribute("aria-label", `${title || "Item"} options`);
  menu.classList.toggle("full-player-context", showHeader);
  const actionMarkup = actions.map((action, index) => {
    if (action.divider) return '<div class="context-divider" role="separator"></div>';
    const classes = [action.danger ? "context-danger" : "", action.emphasis ? "context-emphasis" : ""].filter(Boolean).join(" ");
    return `<button class="${classes}" type="button" role="menuitem" data-context-action="${index}" ${action.disabled ? "disabled" : ""}>
      <span class="context-action-icon" aria-hidden="true">${action.icon || ""}</span>
      <span class="context-action-label">${escapeHTML(action.label)}</span>
      ${action.trailing ? `<span class="context-action-trailing">${escapeHTML(action.trailing)}</span>` : ""}
    </button>`;
  }).join("");
  const headerMarkup = showHeader ? `<div class="context-menu-header"><strong>${escapeHTML(title || "Untitled")}</strong><small>${escapeHTML(subtitle || "Unknown artist")}</small></div>` : "";
  menu.innerHTML = `${headerMarkup}${actionMarkup}`;
  menu.hidden = false;
  const positionMenu = () => {
    const requestedLeft = activeContextMenuAlignEnd ? activeContextMenuPosition.x - menu.offsetWidth : activeContextMenuPosition.x;
    menu.style.left = `${Math.max(8, Math.min(requestedLeft, innerWidth - menu.offsetWidth - 8))}px`;
    menu.style.top = `${Math.max(8, Math.min(activeContextMenuPosition.y, innerHeight - menu.offsetHeight - 8))}px`;
  };
  positionMenu();
  menu.querySelectorAll("[data-context-action]").forEach((button) => {
    const action = actions[Number(button.dataset.contextAction)];
    button.onclick = async (clickEvent) => {
      clickEvent.stopPropagation();
      if (!action || action.disabled) return;
      if (!action.keepOpen) closeTrackContextMenu();
      try {
        await action.onSelect?.();
      } catch (error) {
        showNotice(error?.message || "Resonance could not complete that action.");
      }
    };
  });
  menu.onkeydown = (keyEvent) => {
    const items = [...menu.querySelectorAll('[role="menuitem"]:not(:disabled)')];
    const currentIndex = items.indexOf(document.activeElement);
    if (keyEvent.key === "Escape") {
      keyEvent.preventDefault();
      closeTrackContextMenu({ restoreFocus: true });
    } else if (["ArrowDown", "ArrowUp", "Home", "End"].includes(keyEvent.key) && items.length) {
      keyEvent.preventDefault();
      const nextItemIndex = keyEvent.key === "Home" ? 0
        : keyEvent.key === "End" ? items.length - 1
          : (currentIndex + (keyEvent.key === "ArrowUp" ? -1 : 1) + items.length) % items.length;
      items[nextItemIndex].focus();
    }
  };
  requestAnimationFrame(() => {
    positionMenu();
    menu.querySelector('[role="menuitem"]:not(:disabled)')?.focus();
  });
}

function renderTrackPlaylistContextMenu(track, options) {
  const activePlaylist = state.playlists.find((item) => item.id === options.playlistID && !item.isSystem);
  const playlists = state.playlists.filter((item) => !item.isSystem && item.id !== activePlaylist?.id);
  renderContextMenu({
    title: "Add to playlist",
    subtitle: track.title || "Untitled",
    actions: [
      { label: "Back", icon: contextBackIcon, keepOpen: true, onSelect: () => renderTrackContextMenu(track, options) },
      { divider: true },
      ...playlists.map((playlist) => ({
        label: playlist.name,
        icon: contextPlaylistIcon,
        disabled: playlist.trackIDs.includes(track.id),
        trailing: playlist.trackIDs.includes(track.id) ? "Added" : "",
        onSelect: async () => {
          playlist.trackIDs.push(track.id);
          updatePlaylistRemoteSongIDs(state, playlist);
          markPlaylistDirty(playlist);
          if (activePlaybackPlaylistID === playlist.id) setPlaybackContext(tracksForPlaylist(state, playlist.id), playlist.id);
          await persist();
          schedulePlaylistSync();
          showNotice(`Added ${track.title || "song"} to ${playlist.name}.`, "status");
        },
      })),
      ...(playlists.length ? [{ divider: true }] : []),
      { label: "New playlist", icon: contextPlaylistIcon, onSelect: () => newPlaylist(track.id) },
    ],
  });
}

function renderTrackContextMenu(track, options = {}) {
  const activePlaylist = state.playlists.find((item) => item.id === options.playlistID && !item.isSystem);
  const playing = track.id === currentID && playbackIsActive();
  const liked = state.favorites.includes(track.id);
  const playbackTracks = options.playbackTracks?.length ? options.playbackTracks : tracksForActiveProfile(state);
  const actions = [
    {
      label: playing ? "Pause" : "Play",
      icon: playing ? contextPauseIcon : contextPlayIcon,
      onSelect: () => track.id === currentID ? toggle() : play(track, playbackTracks, { playlistID: options.playlistID ?? null }),
    },
    { label: liked ? "Remove from Liked Songs" : "Add to Liked Songs", icon: contextHeartIcon, onSelect: () => toggleFavorite(track.id) },
  ];
  if (options.source === "full-player" && isInstalledVideoTrack(track)) {
    actions.unshift(
      {
        label: "Watch Video",
        icon: contextVideoIcon,
        emphasis: true,
        onSelect: () => openInstalledVideo(track),
      },
      { divider: true },
    );
  }
  if (activePlaylist) {
    actions.push({
      label: `Remove from ${activePlaylist.name}`,
      icon: contextRemoveIcon,
      danger: true,
      onSelect: async () => {
        activePlaylist.trackIDs = activePlaylist.trackIDs.filter((id) => id !== track.id);
        updatePlaylistRemoteSongIDs(state, activePlaylist);
        markPlaylistDirty(activePlaylist);
        if (activePlaybackPlaylistID === activePlaylist.id) setPlaybackContext(tracksForPlaylist(state, activePlaylist.id), activePlaylist.id);
        await persist();
        schedulePlaylistSync();
        renderLibrary();
      },
    });
  }
  actions.push(
    { label: "Add to playlist", icon: contextPlaylistIcon, trailing: "›", keepOpen: true, onSelect: () => renderTrackPlaylistContextMenu(track, options) },
  );
  actions.push(
    { divider: true },
    {
      label: "Remove from device",
      icon: contextTrashIcon,
      danger: true,
      onSelect: async () => {
        if (confirm(`Remove ${track.title || "this song"} from this device?`)) await deleteStoredTracks([track.id]);
      },
    },
  );
  renderContextMenu({
    title: track.title || "Untitled",
    subtitle: track.artist || "Unknown artist",
    actions,
    showHeader: options.source === "full-player",
  });
}

function openTrackContextMenu(event, trackID, options = {}) {
  const track = state.tracks.find((item) => item.id === trackID && trackBelongsToActiveProfile(state, item));
  if (!track || track.transientStream) return;
  beginContextMenu(event, { alignToEnd: options.alignToEnd });
  renderTrackContextMenu(track, options);
}

async function deletePlaylistFromContext(playlist) {
  if (!playlist || playlist.isSystem || !confirm(`Delete ${playlist.name}?`)) return;
  markPlaylistDeleted(playlist);
  state.playlists = state.playlists.filter((item) => item.id !== playlist.id);
  if (selectedPlaylistID === playlist.id) {
    selectedPlaylistID = null;
    section = "playlists";
  }
  await persist();
  schedulePlaylistSync();
  render();
}

function openPlaylistContextMenu(event, playlistID) {
  const playlist = state.playlists.find((item) => item.id === playlistID);
  if (!playlist) return;
  beginContextMenu(event);
  const tracks = tracksForPlaylist(state, playlist.id);
  const actions = [
    { label: "Open", icon: contextOpenIcon, onSelect: () => navigate("library", playlist.id) },
    { label: "Play", icon: contextPlayIcon, disabled: !tracks.length, onSelect: () => play(tracks[0], tracks, { playlistID: playlist.id }) },
  ];
  if (!playlist.isSystem) actions.push(
    { divider: true },
    { label: "Delete playlist", icon: contextTrashIcon, danger: true, onSelect: () => deletePlaylistFromContext(playlist) },
  );
  renderContextMenu({ title: playlist.name, subtitle: `${tracks.length} track${tracks.length === 1 ? "" : "s"}`, actions });
}

function openServerTrackContextMenu(event, songID) {
  const song = serverCatalog.find((item) => item.id === songID);
  if (!song) return;
  beginContextMenu(event);
  const localTrack = playableActiveRemoteTrack(song.id);
  const offlineDownloadAvailable = currentServerTransferModes().downloadMode === "verified_file_cache";
  const requiresDownload = serverSongRequiresDownload(song);
  const actions = [
    localTrack
      ? { label: "Play on this device", icon: contextPlayIcon, onSelect: () => play(localTrack, tracksForActiveProfile(state), { playlistID: null }) }
      : {
        label: offlineDownloadAvailable ? "Download" : requiresDownload ? "Video requires download" : "Play from server",
        icon: offlineDownloadAvailable ? contextDownloadIcon : contextPlayIcon,
        disabled: !offlineDownloadAvailable && requiresDownload,
        onSelect: async () => {
          if (!offlineDownloadAvailable) await playRemoteStream(song);
          else {
            selectedRemoteIDs = new Set([song.id]);
            await serverAction("selected");
          }
        },
      },
    { divider: true },
    {
      label: "Delete from server",
      icon: contextTrashIcon,
      danger: true,
      onSelect: async () => {
        if (!confirm(`Delete ${song.title || song.name} from the server?`)) return;
        await saveServerForm();
        await api.deleteServerSong({ baseURL: state.serverURL, adminToken: serverAdminToken, profileID: activeProfileID(), songID: song.id });
        await serverAction("catalog");
      },
    },
  ];
  renderContextMenu({
    title: song.title || song.name || "Server song",
    subtitle: song.artist || (localTrack ? "On this device" : "Music Server"),
    actions,
  });
}

async function importAudio() {
  try {
    const tracks = await api.importAudio();
    if (!tracks.length) return;
    state.tracks.push(...tracks);
    if (!currentID && tracks[0]) {
      currentID = tracks[0].id;
      state.currentTrackID = currentID;
      setPlaybackContext(tracksForActiveProfile(state), null);
    }
    await persist();
    render(); updateChrome();
    showNotice(`Imported ${tracks.length} song${tracks.length === 1 ? "" : "s"}.`, "status");
  } catch (error) {
    showNotice(error.message || "Resonance could not import the selected audio.");
  }
}

function setLocalImportStage(value = { stage: "idle" }) {
  const stage = value.stage || "idle";
  $("#localImportStage").dataset.stage = stage;
  $("#localImportDialog").classList.toggle("expanded", stage !== "idle");
}

function setLocalImportProviderFocus(provider, { scroll = false } = {}) {
  if (!LOCAL_IMPORT_PROVIDER_ORDER.some(([candidate]) => candidate === provider)) return;
  localImportProviderFocus = provider;
  document.querySelectorAll("[data-local-import-provider]").forEach((button) => {
    button.setAttribute("aria-pressed", String(button.dataset.localImportProvider === provider));
  });
  if (scroll) {
    document.querySelector(`[data-search-provider="${provider}"]`)?.scrollIntoView({ behavior: "smooth", block: "nearest" });
  }
}

function localImportProviderForSource(value) {
  const source = String(value || "").toLowerCase();
  if (source.includes("spotify.com")) return "spotify";
  if (source.includes("soundcloud.com") || source.includes("on.soundcloud.com")) return "soundcloud";
  if (source.includes("youtube.com") || source.includes("youtu.be")) return "youtube";
  return null;
}

function showLocalImportError(error) {
  const node = $("#localImportError");
  const stage = String(error?.stage || "failed").replaceAll("_", " ");
  node.textContent = `${error?.message || "Resonance could not complete the local import."} (${stage})`;
  node.hidden = false;
  if (!$("#localImportDialog").open) showNotice(node.textContent);
  setLocalImportStage({ stage: error?.code === "CANCELLED" ? "cancelled" : "failed" });
}

function selectedLocalImportMediaKind() {
  return document.querySelector('input[name="localImportMediaKind"]:checked')?.value === "video" ? "video" : "audio";
}

function localImportSelectionValues(selectionName = null) {
  if (!selectionName) return [];
  return [...document.querySelectorAll(`input[name="${selectionName}"]:checked`)].map((input) => input.value);
}

function localImportOperationSnapshot(selectionName = null, { requiresResolvedSource = false } = {}) {
  return Object.freeze({
    generation: localImportInteractionGeneration,
    fingerprint: localImportOperationFingerprint({
      source: $("#localImportSource").value,
      mediaKind: selectedLocalImportMediaKind(),
      selection: localImportSelectionValues(selectionName),
      uploadRequested: $("#localImportSync").checked,
    }),
    selectionName,
    requiresResolvedSource,
  });
}

function localImportOperationCurrent(snapshot) {
  const current = localImportOperationIsCurrent(snapshot, {
    generation: localImportInteractionGeneration,
    fingerprint: localImportOperationFingerprint({
      source: $("#localImportSource").value,
      mediaKind: selectedLocalImportMediaKind(),
      selection: localImportSelectionValues(snapshot?.selectionName),
      uploadRequested: $("#localImportSync").checked,
    }),
  });
  if (!current || !snapshot?.requiresResolvedSource) return current;
  return localImportResolvedSourceKey === `${selectedLocalImportMediaKind()}:${$("#localImportSource").value.trim()}`;
}

function requireCurrentLocalImportOperation(snapshot) {
  if (!localImportOperationCurrent(snapshot)) {
    throw {
      stage: "awaiting_selection",
      code: "STALE_IMPORT_SELECTION",
      message: "The source or selection changed. Review the visible choice and start the import again.",
    };
  }
}

function setLocalImportOperationLocked(locked, { keepSourceEditable = false } = {}) {
  $("#localImportSource").disabled = locked && !keepSourceEditable;
  $("#searchLocalImport").disabled = locked;
  $("#chooseLocalFiles").disabled = locked;
  setLocalImportMediaKindDisabled(locked);
  document.querySelectorAll('input[name="localImportCandidate"], input[name="localImportPlaylistItem"]').forEach((input) => {
    input.disabled = locked;
  });
  document.querySelectorAll("[data-local-import-preview]").forEach((button) => {
    const candidate = localImportResolution?.candidates?.[Number(button.dataset.localImportPreview)];
    button.disabled = locked || !localImportCandidateCanPreview(candidate);
  });
  $("#localImportSync").disabled = locked;
  $("#confirmLocalImport").disabled = locked;
  if (!locked) updateLocalImportSyncForSelection({ preserveChecked: true });
}

function setLocalImportMediaKindDisabled(disabled) {
  document.querySelectorAll('input[name="localImportMediaKind"]').forEach((input) => { input.disabled = disabled; });
  $("#localImportMediaKind").classList.toggle("disabled", disabled);
}

function updateLocalImportMediaKindUI() {
  const video = selectedLocalImportMediaKind() === "video";
  const confirm = $("#confirmLocalImport");
  const confirmLabel = video ? "Download video" : "Download audio";
  confirm.title = confirmLabel;
  confirm.setAttribute("aria-label", confirmLabel);
}

function updateLocalImportConfirmLabel() {
  const confirm = $("#confirmLocalImport");
  if (localImportResolution?.kind?.endsWith("_playlist")) {
    const count = document.querySelectorAll('input[name="localImportPlaylistItem"]:checked').length;
    const noun = selectedLocalImportMediaKind() === "video" ? "video" : "song";
    const label = count ? `Download ${count} ${noun}${count === 1 ? "" : "s"}` : `Choose ${noun}s`;
    confirm.title = label;
    confirm.setAttribute("aria-label", label);
    confirm.disabled = count === 0;
    return;
  }
  updateLocalImportMediaKindUI();
}

function localImportSourceIsReady(value) {
  let url;
  try { url = new URL(String(value || "").trim()); }
  catch { return false; }
  if (url.protocol !== "https:" || url.username || url.password) return false;
  const hostname = url.hostname.toLowerCase();
  const segments = url.pathname.split("/").filter(Boolean);
  if (["open.spotify.com", "www.open.spotify.com"].includes(hostname)) {
    if (segments[0]?.startsWith("intl-")) segments.shift();
    return ["track", "playlist"].includes(segments[0]) && /^[a-zA-Z0-9]{22}$/.test(segments[1] || "");
  }
  if (["spotify.link", "www.spotify.link"].includes(hostname)) return segments.length > 0;
  if (["soundcloud.com", "www.soundcloud.com", "m.soundcloud.com"].includes(hostname)) return segments.length >= 2;
  if (hostname === "on.soundcloud.com") return segments.length > 0;
  if (["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be"].includes(hostname)) {
    const playlistID = url.searchParams.get("list");
    if (playlistID && /^[a-zA-Z0-9_-]{10,150}$/.test(playlistID)) return true;
  }
  if (["youtu.be", "www.youtu.be"].includes(hostname)) return /^[a-zA-Z0-9_-]{11}$/.test(segments[0] || "");
  if (["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"].includes(hostname)) {
    if (url.pathname === "/watch") return /^[a-zA-Z0-9_-]{11}$/.test(url.searchParams.get("v") || "");
    return ["embed", "live", "shorts"].includes(segments[0] || "")
      && /^[a-zA-Z0-9_-]{11}$/.test(segments[1] || "");
  }
  return false;
}

function localImportInputIsLink(value) {
  const input = String(value || "").trim();
  if (!input || /\s/.test(input)) return /^[a-z][a-z0-9+.-]*:\/\//i.test(input);
  return /^[a-z][a-z0-9+.-]*:\/\//i.test(input)
    || /^www\./i.test(input)
    || /^[^/?#]+\.[a-z]{2,}(?:[/?#:]|$)/i.test(input);
}

function normalizeLocalImportMediaKindForSource() {
  const source = $("#localImportSource").value.trim();
  let hostname = "";
  try { hostname = new URL(source).hostname.toLowerCase(); }
  catch { /* A plain-text query can search for either audio or video. */ }
  const audioOnly = [
    "open.spotify.com", "www.open.spotify.com", "spotify.link", "www.spotify.link",
    "soundcloud.com", "www.soundcloud.com", "m.soundcloud.com", "on.soundcloud.com",
  ].includes(hostname);
  if (!audioOnly || selectedLocalImportMediaKind() === "audio") return;
  const audioKind = document.querySelector('input[name="localImportMediaKind"][value="audio"]');
  if (audioKind) audioKind.checked = true;
  updateLocalImportMediaKindUI();
}

function clearLocalImportAutoResolve() {
  if (localImportAutoResolveTimer !== null) clearTimeout(localImportAutoResolveTimer);
  localImportAutoResolveTimer = null;
}

function updateDirectServerSourceImportState() {
  if (localImportServerUploadMode !== "server_source_link") return false;
  const ready = Boolean(exactYouTubeSourcePageURL($("#localImportSource").value));
  const confirm = $("#confirmLocalImport");
  confirm.hidden = !ready;
  confirm.disabled = !ready || localImportRunning;
  confirm.title = "Upload source link";
  confirm.setAttribute("aria-label", "Upload source link");
  $("#localImportResolved").hidden = true;
  $("#localImportSyncRow").hidden = true;
  $("#cancelLocalImport").hidden = true;
  setLocalImportStage({ stage: ready ? "awaiting_selection" : "idle" });
  return ready;
}

function scheduleLocalImportResolution({ immediate = false } = {}) {
  clearLocalImportAutoResolve();
  if (localImportRunning) return;
  const source = $("#localImportSource").value.trim();
  if (!localImportSourceIsReady(source)) return;
  const sourceKey = `${selectedLocalImportMediaKind()}:${source}`;
  if (localImportResolution && localImportResolvedSourceKey === sourceKey) return;
  localImportAutoResolveTimer = setTimeout(() => {
    localImportAutoResolveTimer = null;
    void resolveLinkImport();
  }, immediate ? 0 : LOCAL_IMPORT_AUTO_RESOLVE_DELAY);
}

function resetLocalImport() {
  localImportInteractionGeneration += 1;
  void stopLocalImportPreview({ release: true, resumeMain: true });
  clearLocalImportAutoResolve();
  localImportResolution = null;
  localImportResolutionRestartPending = false;
  localImportResolvedSourceKey = null;
  localImportBatchContext = null;
  localImportServerUploadMode = null;
  localImportRunning = false;
  localImportArtworkRequest += 1;
  const audioKind = document.querySelector('input[name="localImportMediaKind"][value="audio"]');
  if (audioKind) audioKind.checked = true;
  setLocalImportMediaKindDisabled(false);
  $("#localImportSource").disabled = false;
  $("#searchLocalImport").disabled = false;
  $("#localImportSource").removeAttribute("aria-busy");
  $("#localImportSource").closest(".local-import-source").classList.remove("searching");
  $("#localImportResolved").hidden = true;
  $("#localImportSyncRow").hidden = true;
  $("#localImportCandidates").innerHTML = "";
  $("#localImportError").hidden = true;
  $("#confirmLocalImport").hidden = true;
  $("#cancelLocalImport").hidden = true;
  $("#chooseLocalFiles").disabled = false;
  $("#chooseLocalFiles").title = "Choose files";
  $("#chooseLocalFiles").setAttribute("aria-label", "Choose files");
  $("#localImportSync").checked = false;
  setLocalImportStage({ stage: "idle" });
  updateLocalImportMediaKindUI();
  $("#localImportMediaKind").hidden = false;
  $("#localImportProviderPill").hidden = false;
  setLocalImportProviderFocus("youtube");
  $("#chooseLocalFiles").hidden = false;
  $("#localImportTitle").textContent = "Import from Link";
  $("#localImportSource").placeholder = "Link or music search";
}

function openLocalImport({ serverUploadMode = null } = {}) {
  resetLocalImport();
  if (["local_file", "server_source_link", "reviewed_match"].includes(serverUploadMode)) {
    localImportServerUploadMode = serverUploadMode;
    $("#localImportTitle").textContent = serverUploadMode === "reviewed_match" ? "Upload reviewed source" : "Upload source link";
    $("#localImportSource").placeholder = serverUploadMode === "reviewed_match"
      ? "YouTube song link or music search…"
      : "Song link or music search…";
    $("#localImportMediaKind").hidden = true;
    $("#localImportProviderPill").hidden = true;
    $("#chooseLocalFiles").hidden = true;
    $("#localImportSync").checked = true;
  }
  $("#localImportSource").value = "";
  $("#localImportDialog").showModal();
  requestAnimationFrame(() => $("#localImportSource").focus());
}

function localImportProviderLabel(candidate) {
  if (candidate.searchProvider === "spotify") return "Spotify";
  if (candidate.searchProvider === "soundcloud") return "SoundCloud";
  if (candidate.searchProvider === "youtube") return "YouTube";
  if (candidate.sourceProvider === "soundcloud") return "SoundCloud";
  if (candidate.sourceProvider === "youtube_music") return "YouTube Music";
  if (candidate.sourceProvider === "debrid_vault") return "Debrid Vault";
  if (candidate.sourceProvider === "torbox_file") return "TorBox file";
  return "YouTube";
}

function localImportSourceIdentity(candidate, metadata = {}) {
  return buildLocalImportSourceIdentity(candidate, metadata);
}

function backfillLocalImportSourceIdentity(track, sourceIdentity) {
  return mergeTrackSourceIdentity(track, sourceIdentity);
}

function localImportCandidateDetails(candidate) {
  if (localImportResolution?.kind === "search_results") {
    const metadata = candidate.importMetadata || candidate;
    const previewProvider = candidate.sourceProvider === "soundcloud"
      ? "SoundCloud"
      : candidate.sourceProvider === "youtube_music" ? "YouTube Music" : "YouTube";
    const resultProvider = localImportProviderLabel(candidate);
    return [
      metadata.artist || "Unknown artist",
      metadata.album,
      metadata.durationSeconds ? formatTime(metadata.durationSeconds) : null,
      previewProvider !== resultProvider
        ? `${localImportResolution?.mediaKind === "video" ? "Video" : "Preview"} via ${previewProvider}`
        : null,
    ];
  }
  if (localImportResolution?.kind?.endsWith("_playlist")) {
    const metadata = candidate.importMetadata || candidate;
    return [metadata.artist || "Unknown artist", metadata.durationSeconds ? formatTime(metadata.durationSeconds) : null, candidate.requiresReview || candidate.requires_review ? "Review match" : null, localImportProviderLabel(candidate)];
  }
  if (localImportResolution?.mediaKind === "video") {
    const dimensions = candidate.width && candidate.height ? `${candidate.width}×${candidate.height}` : null;
    return [candidate.qualityLabel || "MP4", dimensions, candidate.fps ? `${candidate.fps} fps` : null, candidate.durationSeconds ? formatTime(candidate.durationSeconds) : null, localImportProviderLabel(candidate)];
  }
  if (candidate.sourceProvider === "debrid_vault") {
    return [candidate.quality, Number.isFinite(candidate.seeders) ? `${candidate.seeders} seeders` : null, candidate.size ? formatBytes(candidate.size) : null, candidate.requiresReview || candidate.requires_review ? "Review match" : null, localImportProviderLabel(candidate)];
  }
  if (candidate.sourceProvider === "torbox_file") {
    return [candidate.size ? formatBytes(candidate.size) : null, candidate.contentType, localImportProviderLabel(candidate)];
  }
  return [candidate.artist || "Unknown uploader", candidate.durationSeconds ? formatTime(candidate.durationSeconds) : null, localImportProviderLabel(candidate)];
}

function localImportCandidateCanPreview(candidate) {
  return localImportResolution?.mediaKind === "audio"
    && !candidate?.serverBacked
    && ["soundcloud", "youtube", "youtube_music"].includes(candidate?.sourceProvider)
    && typeof candidate?.sourceURL === "string";
}

function syncLocalImportPreviewButtons() {
  document.querySelectorAll("[data-local-import-preview]").forEach((button) => {
    const index = Number(button.dataset.localImportPreview);
    const candidate = localImportResolution?.candidates?.[index];
    const loading = localImportPreviewLoadingIndex === index;
    const playing = localImportPreviewIndex === index && !localImportPreviewAudio.paused;
    const title = candidate?.title || "this source";
    button.classList.toggle("loading", loading);
    button.classList.toggle("playing", playing);
    button.setAttribute("aria-pressed", String(playing));
    button.setAttribute("aria-label", loading ? `Preparing preview for ${title}` : `${playing ? "Pause" : "Preview"} ${title}`);
    button.title = loading ? "Preparing preview…" : playing ? "Pause preview" : "Preview source";
  });
}

async function resumePlaybackAfterLocalImportPreview() {
  if (!localImportPreviewInterruptedPlayback) return;
  localImportPreviewInterruptedPlayback = false;
  if (currentTrack() && audio.paused) await requestPlayback();
}

async function stopLocalImportPreview({ release = false, resumeMain = true, preserveInterruption = false } = {}) {
  const interrupted = localImportPreviewInterruptedPlayback;
  localImportPreviewRequest += 1;
  localImportPreviewAudio.pause();
  localImportPreviewIndex = null;
  localImportPreviewLoadingIndex = null;
  localImportPreviewLimitSeconds = 30;
  if (release) {
    localImportPreviewAudio.removeAttribute("src");
    localImportPreviewAudio.load();
    await api.cancelLocalImportPreview().catch(() => undefined);
  }
  syncLocalImportPreviewButtons();
  if (resumeMain && interrupted) await resumePlaybackAfterLocalImportPreview();
  else if (!preserveInterruption) localImportPreviewInterruptedPlayback = false;
}

async function toggleLocalImportPreview(index) {
  const candidate = localImportResolution?.candidates?.[index];
  if (!candidate || !localImportCandidateCanPreview(candidate)) return;
  if (localImportPreviewLoadingIndex === index) {
    await stopLocalImportPreview({ release: true, resumeMain: true });
    return;
  }
  if (localImportPreviewIndex === index && localImportPreviewAudio.src) {
    if (localImportPreviewAudio.paused) {
      if (!audio.paused) {
        localImportPreviewInterruptedPlayback = true;
        audio.pause();
        updateChrome();
      }
      if (localImportPreviewAudio.currentTime >= localImportPreviewLimitSeconds) localImportPreviewAudio.currentTime = 0;
      await localImportPreviewAudio.play();
    } else {
      localImportPreviewAudio.pause();
      await resumePlaybackAfterLocalImportPreview();
    }
    syncLocalImportPreviewButtons();
    return;
  }

  const switchingPreview = localImportPreviewIndex !== null || localImportPreviewLoadingIndex !== null;
  if (switchingPreview) {
    await stopLocalImportPreview({ release: true, resumeMain: false, preserveInterruption: true });
  }
  if (!localImportPreviewInterruptedPlayback && !audio.paused) {
    localImportPreviewInterruptedPlayback = true;
    audio.pause();
    updateChrome();
  }
  const request = ++localImportPreviewRequest;
  localImportPreviewLoadingIndex = index;
  syncLocalImportPreviewButtons();
  try {
    const response = await api.previewLocalImport(candidate.sourceURL);
    if (request !== localImportPreviewRequest) return;
    if (!response?.ok) throw response?.error || { message: "This source could not be previewed." };
    localImportPreviewLoadingIndex = null;
    localImportPreviewIndex = index;
    localImportPreviewLimitSeconds = Math.max(1, Number(response.result.durationSeconds) || 30);
    localImportPreviewAudio.src = response.result.fileURL;
    localImportPreviewAudio.volume = playbackGainForVolume(state.volume);
    localImportPreviewAudio.currentTime = 0;
    await localImportPreviewAudio.play();
  } catch (error) {
    if (request !== localImportPreviewRequest) return;
    await stopLocalImportPreview({ release: true, resumeMain: true });
    if (error?.code !== "CANCELLED") showNotice(error?.message || "This source could not be previewed.");
  } finally {
    if (request === localImportPreviewRequest) {
      localImportPreviewLoadingIndex = null;
      syncLocalImportPreviewButtons();
    }
  }
}

function updateLocalImportSyncForSelection({ preserveChecked = false } = {}) {
  const selected = document.querySelector('input[name="localImportCandidate"]:checked, input[name="localImportPlaylistItem"]:checked');
  const candidate = selected ? localImportResolution?.candidates?.[Number(selected.value)] : null;
  const serverBacked = Boolean(candidate?.serverBacked);
  const canSync = Boolean(serverAdminToken.trim() && state.serverURL);
  const sync = $("#localImportSync");
  const row = $("#localImportSyncRow");
  if (!preserveChecked) sync.checked = true;
  sync.disabled = serverBacked;
  row.classList.toggle("disabled", serverBacked);
  row.title = serverBacked
    ? "This source is already saved to the active server profile."
    : canSync
      ? "Upload a copy to the active server profile after downloading."
      : "Sign in to your Resonance account before importing to upload this copy.";
  updateLocalImportConfirmLabel();
}

function localImportUploadConfigurationError(serverBacked = false, context = null) {
  if (serverBacked || !$("#localImportSync").checked) return null;
  if (!(context?.serverURL || state.serverURL)) {
    return { stage: "syncing", code: "SERVER_URL_REQUIRED", message: "Add a server URL in Music Server settings before uploading." };
  }
  if (!String(context?.adminToken ?? serverAdminToken).trim()) {
    return { stage: "syncing", code: "ADMIN_KEY_REQUIRED", message: "Sign in to your Resonance account before uploading." };
  }
  return null;
}

function requireTrackUploadAssociationContext(track, context) {
  const conflict = remoteAssociationConflictMessage(track, {
    serverURL: context?.serverURL,
    profileID: context?.profileID,
  });
  if (conflict) throw new Error(conflict);
}

async function uploadLocalImportTrack(track, context) {
  return uploadImportedTrackWithMode(track, context, "local_file");
}

async function uploadReviewedMatchTrack(track, context) {
  return uploadImportedTrackWithMode(track, context, "reviewed_match");
}

async function uploadImportedTrackWithMode(track, context, mode) {
  requireLocalImportServerContext(context);
  requireTrackUploadAssociationContext(track, context);
  if (!track?.filePath) {
    return { ok: false, error: { stage: "syncing", code: "LOCAL_FILE_MISSING", message: "The local song file could not be found for server upload." } };
  }
  const existingRemoteSong = serverCatalogMatchForLocalImport(track, context);
  if (existingRemoteSong) {
    if (reconcileUploadedTrack(state, track.id, existingRemoteSong, {
      serverURL: context.serverURL,
      profileID: context.profileID,
    })) {
      playlistMutationGeneration += 1;
      await persist({ refreshSidebar: false });
      requireLocalImportServerContext(context);
      schedulePlaylistSync();
    }
    return { ok: true, remoteSong: existingRemoteSong, skipped: true };
  }
  const result = await api.uploadLocalImport({
    baseURL: context.serverURL,
    adminToken: context.adminToken,
    profileID: context.profileID,
    filePath: track.filePath,
    title: track.title || "Untitled song",
    artist: track.artist || "Unknown Artist",
    album: track.album || "Unknown Album",
    duration: Number(track.duration) || 0,
    artworkURL: track.artworkURL || null,
    mediaSourceURL: preservedUploadSourceURL(track),
    mediaKind: isInstalledVideoTrack(track) ? "video" : "audio",
    mode,
  });
  requireLocalImportServerContext(context);
  if (result?.ok && result.remoteSong) rememberUploadedServerSongs([{ remoteSong: result.remoteSong }]);
  if (result?.ok && result.remoteSong && reconcileUploadedTrack(state, track.id, result.remoteSong, {
    serverURL: context.serverURL,
    profileID: context.profileID,
  })) {
    playlistMutationGeneration += 1;
    await persist({ refreshSidebar: false });
    requireLocalImportServerContext(context);
    schedulePlaylistSync();
  }
  return result;
}

async function refreshServerCatalogAfterUpload(context) {
  if (!context?.serverURL || !context.token?.trim()) return false;
  const requestGeneration = serverCatalogGeneration;
  try {
    const catalog = await api.fetchCatalog({
      baseURL: context.serverURL,
      token: context.token,
      profileID: context.profileID,
    });
    if (!catalogRequestCanApply({
      requestGeneration,
      currentGeneration: serverCatalogGeneration,
      contextCurrent: profileContextIsCurrent(context),
    })) return false;
    replaceServerCatalog(catalog.songs);
    hydrateServerCatalogArtwork(serverCatalog);
    const count = Number.isFinite(Number(catalog.count)) ? Number(catalog.count) : serverCatalog.length;
    serverConnectionText = `Connected • ${count} song${count === 1 ? "" : "s"}`;
    serverConnected = true;
    if (section === "server") renderServer();
    schedulePlaylistSync();
    return true;
  } catch {
    // The upload already succeeded. A catalog refresh failure should not report
    // that the saved server copy was lost.
    return false;
  }
}

function scheduleServerCatalogRefresh(context = currentProfileContext()) {
  queueMicrotask(() => { void refreshServerCatalogAfterUpload(context); });
}

function rememberUploadedServerSongs(results) {
  const merged = mergeUploadedSongsIntoCatalog(serverCatalog, results);
  if (merged.length === serverCatalog.length && merged.every((song, index) => song === serverCatalog[index])) return;
  replaceServerCatalog(merged);
  serverConnected = true;
  hydrateServerCatalogArtwork(serverCatalog);
  if (section === "server") renderServer();
}

function serverCatalogMatchForLocalImport(track, context) {
  requireLocalImportServerContext(context);
  const remoteID = String(track?.remoteID || "").trim();
  if (remoteID && serverTrackRemoteIDBelongsToContext(track, {
    serverURL: context.serverURL,
    profileID: context.profileID,
  })) {
    const remoteMatch = serverCatalog.find((song) => String(song?.id || "").trim() === remoteID);
    if (remoteMatch) return remoteMatch;
  }
  const contentHash = String(track?.contentSha256 || "").trim().toLocaleLowerCase();
  const hashMatch = contentHash
    ? serverCatalog.find((song) =>
      String(song?.content_sha256 || song?.contentSha256 || "").trim().toLocaleLowerCase() === contentHash)
    : null;
  return hashMatch || null;
}

async function prepareLocalImportUploadBatch(tracks, context) {
  requireLocalImportServerContext(context);
  const pending = [];
  let reconciled = false;
  for (const track of tracks) {
    requireTrackUploadAssociationContext(track, context);
    const remoteSong = serverCatalogMatchForLocalImport(track, context);
    if (remoteSong) {
      reconciled = reconcileUploadedTrack(state, track.id, remoteSong, {
        serverURL: context.serverURL,
        profileID: context.profileID,
      }) || reconciled;
      continue;
    }
    pending.push(track);
  }
  if (reconciled) {
    playlistMutationGeneration += 1;
    await persist({ refreshSidebar: false });
    requireLocalImportServerContext(context);
    schedulePlaylistSync();
  }
  return pending;
}

async function uploadLocalImportTracks(tracks, context) {
  requireLocalImportServerContext(context);
  tracks.forEach((track) => requireTrackUploadAssociationContext(track, context));
  const result = await api.uploadServer({
    baseURL: context.serverURL,
    adminToken: context.adminToken,
    profileID: context.profileID,
    files: tracks.map((track) => ({
      trackID: track.id,
      filePath: track.filePath,
      title: track.title || "Untitled song",
      artist: track.artist || "",
      album: track.album || "",
      duration: Number(track.duration) || 0,
      artworkURL: track.artworkURL || null,
      mediaSourceURL: preservedUploadSourceURL(track),
      mediaKind: isInstalledVideoTrack(track) ? "video" : "audio",
    })),
  });
  requireLocalImportServerContext(context);
  await retainServerUploadManifest(result, context, "link-import");
  requireLocalImportServerContext(context);
  rememberUploadedServerSongs(result?.results);
  let reconciled = false;
  for (const uploaded of result?.results || []) {
    reconciled = reconcileUploadedTrack(state, uploaded.trackID, uploaded.remoteSong, {
      serverURL: context.serverURL,
      profileID: context.profileID,
    }) || reconciled;
  }
  if (reconciled) {
    playlistMutationGeneration += 1;
    await persist({ refreshSidebar: false });
    requireLocalImportServerContext(context);
    schedulePlaylistSync();
  }
  return result;
}

function resetLocalImportArtwork(node, mediaKind) {
  node.classList.remove("loading", "has-image");
  node.textContent = mediaKind === "video" ? "▶" : "♪";
}

async function renderLocalImportArtwork(track, candidates, mediaKind) {
  const node = $(".local-import-art");
  const request = ++localImportArtworkRequest;
  const source = track.artworkURL || candidates.find((candidate) => candidate.thumbnailURL)?.thumbnailURL || null;
  resetLocalImportArtwork(node, mediaKind);
  if (!source) return;
  node.classList.add("loading");
  try {
    const artwork = await api.fetchLocalImportArtwork(source);
    if (request !== localImportArtworkRequest) return;
    if (!artwork) {
      resetLocalImportArtwork(node, mediaKind);
      return;
    }
    const croppedArtwork = await squareArtworkSource(artwork);
    const image = new Image();
    image.alt = "";
    image.decoding = "async";
    image.dataset.squareArtwork = "";
    image.dataset.squareArtworkProcessed = "true";
    await new Promise((resolve, reject) => {
      image.onload = resolve;
      image.onerror = reject;
      image.src = croppedArtwork;
    });
    if (request !== localImportArtworkRequest) return;
    node.replaceChildren(image);
    node.classList.remove("loading");
    node.classList.add("has-image");
  } catch {
    if (request === localImportArtworkRequest) resetLocalImportArtwork(node, mediaKind);
  }
}

async function renderLocalImportPlaylistItemArtwork(node, source, request) {
  if (!source || request !== localImportArtworkRequest) return;
  node.classList.add("loading");
  try {
    const artwork = await api.fetchLocalImportArtwork(source);
    if (!artwork || request !== localImportArtworkRequest) return;
    const image = new Image();
    image.alt = "";
    image.decoding = "async";
    image.src = await squareArtworkSource(artwork);
    await image.decode();
    if (request !== localImportArtworkRequest) return;
    node.replaceChildren(image);
    node.classList.remove("loading");
    node.classList.add("has-image");
  } catch {
    if (request === localImportArtworkRequest) node.classList.remove("loading");
  }
}

function renderLocalImportResolution() {
  const { track, candidates } = localImportResolution;
  const mediaKind = localImportResolution.mediaKind === "video" ? "video" : "audio";
  const playlist = localImportResolution.kind?.endsWith("_playlist");
  const searchResults = localImportResolution.kind === "search_results";
  const showPreviews = mediaKind === "audio" && (searchResults || candidates.length > 1);
  const selectedKind = document.querySelector(`input[name="localImportMediaKind"][value="${mediaKind}"]`);
  if (selectedKind) selectedKind.checked = true;
  $("#localImportResolved").hidden = false;
  $("#localImportResolved").classList.toggle("is-search-results", searchResults);
  $("#localImportResolved").classList.toggle("is-playlist", playlist);
  $("#localImportSyncRow").hidden = Boolean(localImportServerUploadMode);
  void renderLocalImportArtwork(track, candidates, mediaKind);
  $("#localImportTrackTitle").textContent = track.title || "Untitled";
  $("#localImportTrackMeta").textContent = searchResults
    ? [track.artist, "YouTube • Spotify • SoundCloud"].filter(Boolean).join(" • ")
    : playlist
    ? [track.artist, `${candidates.length} available video${candidates.length === 1 ? "" : "s"}`, localImportResolution.playlist?.unavailableCount ? `${localImportResolution.playlist.unavailableCount} unavailable` : null].filter(Boolean).join(" • ")
    : [track.artist, track.album, track.durationSeconds ? formatTime(track.durationSeconds) : null]
    .filter(Boolean).join(" • ");
  $("#localImportCandidateLegend").textContent = searchResults ? "Search results" : playlist ? "Choose playlist songs to import" : "Choose the source to import";
  $("#localImportResultSummary").textContent = searchResults
    ? mediaKind === "video"
      ? `${candidates.length} downloadable`
      : `${candidates.filter(localImportCandidateCanPreview).length} previewable`
    : playlist ? `${candidates.length} available` : `${candidates.length} source${candidates.length === 1 ? "" : "s"}`;
  $("#localImportCandidates").classList.toggle("playlist", playlist);
  $("#localImportCandidates").classList.toggle("search-results", searchResults);
  const candidateMarkup = (candidate, index) => `<label class="local-import-candidate${playlist ? " playlist-item" : ""}${searchResults ? " search-result" : ""}">
    <input type="${playlist ? "checkbox" : "radio"}" name="${playlist ? "localImportPlaylistItem" : "localImportCandidate"}" value="${index}" ${(playlist || index === 0) && localImportCandidateCanAutoSelect(candidate) ? "checked" : ""}>
    ${playlist || searchResults ? `<span class="local-import-item-art" data-local-import-item-art="${index}">♪</span>` : ""}
    <span><strong>${escapeHTML(candidate.importMetadata?.title || candidate.title || "Untitled source")}</strong><small>${escapeHTML(localImportCandidateDetails(candidate).filter(Boolean).join(" • "))}</small></span>
    <span class="local-import-confidence">${searchResults ? escapeHTML(localImportProviderLabel(candidate)) : playlist ? candidate.playlistIndex || index + 1 : escapeHTML(candidate.quality || candidate.confidence || "file")}</span>
    ${showPreviews ? `<button class="local-import-preview-button" type="button" data-local-import-preview="${index}" aria-label="Preview ${escapeHTML(candidate.title || "source")}" aria-pressed="false" title="${localImportCandidateCanPreview(candidate) ? "Preview source" : "Preview unavailable for this source"}" ${localImportCandidateCanPreview(candidate) ? "" : "disabled"}><svg class="preview-play-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5v14l11-7z"/></svg><svg class="preview-pause-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M8 6v12M16 6v12"/></svg></button>` : ""}
  </label>`;
  if (searchResults) {
    $("#localImportCandidates").innerHTML = LOCAL_IMPORT_PROVIDER_ORDER.map(([provider, name]) => {
      const rows = candidates.map((candidate, index) => ({ candidate, index }))
        .filter(({ candidate }) => candidate.searchProvider === provider);
      const emptyCopy = mediaKind === "video" ? "No downloadable videos." : "No previewable results.";
      return `<section class="local-import-search-provider" data-search-provider="${provider}"><h3><span>${name}</span><small>${rows.length} result${rows.length === 1 ? "" : "s"}</small></h3>${rows.length ? rows.map(({ candidate, index }) => candidateMarkup(candidate, index)).join("") : `<p>${emptyCopy}</p>`}</section>`;
    }).join("");
    setLocalImportProviderFocus(localImportProviderFocus);
  } else {
    $("#localImportCandidates").innerHTML = candidates.map(candidateMarkup).join("");
  }
  if (playlist || searchResults) {
    const artworkRequest = localImportArtworkRequest;
    document.querySelectorAll("[data-local-import-item-art]").forEach((node) => {
      const candidate = candidates[Number(node.dataset.localImportItemArt)];
      void renderLocalImportPlaylistItemArtwork(
        node,
        candidate?.importMetadata?.artworkURL || candidate?.thumbnailURL || null,
        artworkRequest,
      );
    });
  }
  document.querySelectorAll('input[name="localImportCandidate"], input[name="localImportPlaylistItem"]').forEach((input) => {
    input.onchange = () => {
      localImportInteractionGeneration += 1;
      updateLocalImportSyncForSelection();
    };
  });
  document.querySelectorAll("[data-local-import-preview]").forEach((button) => {
    button.onclick = (event) => {
      event.preventDefault();
      event.stopPropagation();
      void toggleLocalImportPreview(Number(button.dataset.localImportPreview));
    };
  });
  syncLocalImportPreviewButtons();
  updateLocalImportSyncForSelection();
  $("#confirmLocalImport").hidden = false;
  updateLocalImportConfirmLabel();
  if (localImportServerUploadMode) {
    const label = localImportServerUploadMode === "reviewed_match" ? "Upload reviewed match" : "Upload source link";
    $("#confirmLocalImport").title = label;
    $("#confirmLocalImport").setAttribute("aria-label", label);
  }
  $("#cancelLocalImport").hidden = true;
  setLocalImportStage({ stage: "awaiting_selection" });
}

async function resolveLinkImport() {
  if (localImportRunning) return;
  clearLocalImportAutoResolve();
  normalizeLocalImportMediaKindForSource();
  const source = $("#localImportSource").value.trim();
  if (!source) {
    showLocalImportError({ stage: "resolving_metadata", message: "Enter a song, artist, album, or supported Spotify, SoundCloud, or YouTube link first." });
    return;
  }
  const mediaKind = selectedLocalImportMediaKind();
  const sourceKey = `${mediaKind}:${source}`;
  const reviewedDiscovery = localImportServerUploadMode === "reviewed_match";
  let reviewedContext = null;
  if (reviewedDiscovery) {
    try {
      reviewedContext = currentServerUploadContext();
      if (!reviewedContext.adminToken.trim()) {
        throw { stage: "searching_candidates", code: "ADMIN_KEY_REQUIRED", message: "Sign in to your Resonance account before requesting reviewed matches." };
      }
      reserveServerContext(reviewedContext);
    } catch (error) {
      showLocalImportError(error);
      return;
    }
  }
  const operation = localImportOperationSnapshot();
  localImportRunning = true;
  setLocalImportOperationLocked(true, { keepSourceEditable: true });
  localImportResolution = null;
  localImportResolvedSourceKey = null;
  $("#localImportError").hidden = true;
  $("#localImportResolved").hidden = true;
  $("#localImportSyncRow").hidden = true;
  $("#localImportSource").setAttribute("aria-busy", "true");
  $("#localImportSource").closest(".local-import-source").classList.add("searching");
  $("#cancelLocalImport").hidden = false;
  setLocalImportStage({ stage: localImportInputIsLink(source) ? "resolving_metadata" : "searching_candidates" });
  try {
    await stopLocalImportPreview({ release: true, resumeMain: true });
    requireCurrentLocalImportOperation(operation);
    if (reviewedContext) {
      requireLocalImportServerContext(reviewedContext);
      await requireCurrentServerUploadMode("reviewed_match");
      requireCurrentLocalImportOperation(operation);
      requireLocalImportServerContext(reviewedContext);
    }
    const response = await api.resolveLocalImport({
      source,
      mediaKind,
      baseURL: reviewedContext?.serverURL || state.serverURL,
      adminToken: reviewedContext?.adminToken || "",
      profileID: reviewedContext?.profileID || activeProfileID(),
    });
    requireCurrentLocalImportOperation(operation);
    if (reviewedContext) requireLocalImportServerContext(reviewedContext);
    if (!response?.ok) throw response?.error || { stage: "resolving_metadata", message: "The source could not be resolved." };
    localImportResolution = response.result;
    localImportResolvedSourceKey = sourceKey;
    renderLocalImportResolution();
  } catch (error) {
    if (localImportOperationCurrent(operation) && error?.code !== "CANCELLED") showLocalImportError(error);
  } finally {
    if (reviewedContext) releaseServerContext(reviewedContext);
    const restartResolution = localImportResolutionRestartPending && $("#localImportDialog").open;
    localImportResolutionRestartPending = false;
    localImportRunning = false;
    setLocalImportOperationLocked(false);
    $("#localImportSource").removeAttribute("aria-busy");
    $("#localImportSource").closest(".local-import-source").classList.remove("searching");
    if (!localImportResolution) $("#cancelLocalImport").hidden = true;
    hideServerTransfer("local-import");
    if (restartResolution) scheduleLocalImportResolution();
  }
}

async function confirmPlaylistImport() {
  const resolution = localImportResolution;
  const selected = [...document.querySelectorAll('input[name="localImportPlaylistItem"]:checked')]
    .map((input) => resolution?.candidates?.[Number(input.value)])
    .filter(Boolean);
  const mediaKind = resolution?.mediaKind === "video" ? "video" : "audio";
  if (!selected.length) {
    showLocalImportError({ stage: "awaiting_selection", message: `Choose at least one playlist ${mediaKind === "video" ? "video" : "song"} to download.` });
    return;
  }
  const uploadRequested = $("#localImportSync").checked;
  const needsServerContext = localImportNeedsServerContext({ uploadRequested });
  const uploadConfigurationError = localImportUploadConfigurationError(false);
  if (uploadConfigurationError) {
    showLocalImportError(uploadConfigurationError);
    return;
  }
  let importContext = null;
  if (needsServerContext) {
    try { importContext = currentServerUploadContext(); }
    catch {
      showLocalImportError({ stage: "syncing", code: "SERVER_URL_REQUIRED", message: "Add a valid server URL before uploading." });
      return;
    }
  }
  const playlistTitle = resolution.playlist?.title || resolution.track.title || "Imported Playlist";
  const operation = localImportOperationSnapshot("localImportPlaylistItem", { requiresResolvedSource: true });
  if (importContext) reserveServerContext(importContext);
  localImportRunning = true;
  setLocalImportOperationLocked(true);
  try {
    await stopLocalImportPreview({ release: true, resumeMain: true });
    requireCurrentLocalImportOperation(operation);
    if (importContext) requireLocalImportServerContext(importContext);
  } catch (error) {
    if (importContext) releaseServerContext(importContext);
    localImportRunning = false;
    setLocalImportOperationLocked(false);
    showLocalImportError(error);
    return;
  }
  $("#localImportError").hidden = true;
  $("#cancelLocalImport").hidden = false;
  serverTransferCancelRequested = false;
  localImportKeepStateOnClose = true;
  $("#localImportDialog").close();
  const existing = state.tracks.map((track) => ({
    id: track.id,
    title: track.title,
    filePath: track.filePath,
    sourceSha256: track.sourceSha256 || null,
    contentSha256: track.contentSha256 || null,
  }));
  const created = [];
  const importedTrackIDs = [];
  const uploadQueue = [];
  let duplicates = 0;
  let uploadedCount = 0;
  let cancelled = false;
  let uploadCancelled = false;
  const failures = [];
  const uploadFailures = [];
  let playlistSaved = false;
  const saveImportedPlaylist = async () => {
    if (playlistSaved || !importedTrackIDs.length) return;
    upsertImportedPlaylist(playlistTitle, importedTrackIDs);
    await persist();
    schedulePlaylistSync();
    playlistSaved = true;
  };
  const queueUpload = (track, result) => {
    if (!uploadRequested || !track?.filePath || result?.serverBacked) return;
    if (!uploadQueue.some((queued) => queued.id === track.id)) uploadQueue.push(track);
  };
  try {
    for (let index = 0; index < selected.length; index += 1) {
      if (serverTransferCancelRequested) { cancelled = true; break; }
      const candidate = selected[index];
      localImportBatchContext = { index, total: selected.length, title: candidate.title || `Playlist item ${index + 1}` };
      updateLocalImportTransfer({ stage: "inspecting_source" });
      const importMetadata = candidate.importMetadata || candidate;
      let response = null;
      let lastDownloadError = null;
      const downloadCandidates = [
        candidate,
        ...(Array.isArray(candidate.fallbackCandidates)
          ? candidate.fallbackCandidates.filter(localImportCandidateCanAutoSelect)
          : []),
      ];
      for (const downloadCandidate of downloadCandidates) {
        for (let attempt = 0; attempt < 3; attempt += 1) {
          if (attempt) await new Promise((resolve) => setTimeout(resolve, attempt === 1 ? 400 : 1200));
          try {
            response = await api.startLocalImport({
              sourceURL: downloadCandidate.sourceURL,
              sourceIdentity: localImportSourceIdentity(downloadCandidate, importMetadata),
              mediaKind,
              metadata: {
                title: importMetadata.title,
                artist: importMetadata.artist || "Unknown artist",
                album: importMetadata.album || null,
                durationSeconds: importMetadata.durationSeconds,
                artworkURL: importMetadata.artworkURL || downloadCandidate.thumbnailURL,
                sourceURL: importMetadata.sourceURL || downloadCandidate.sourceURL,
              },
              existing,
            });
          } catch (error) {
            lastDownloadError = error;
            response = null;
          }
          if (response?.ok || response?.error?.code === "CANCELLED") break;
        }
        if (response?.ok || response?.error?.code === "CANCELLED") break;
      }
      if (!response?.ok) {
        if (response?.error?.code === "CANCELLED") { cancelled = true; break; }
        failures.push({
          title: `${importMetadata.title}${importMetadata.artist ? ` — ${importMetadata.artist}` : ""}`,
          message: response?.error?.message || lastDownloadError?.message || "Download failed after three attempts.",
        });
        continue;
      }
      if (importContext) requireLocalImportServerContext(importContext);
      if (response.result.kind === "duplicate") {
        duplicates += 1;
        const duplicate = state.tracks.find((track) => track.id === response.result.trackID) || null;
        if (duplicate) {
          importedTrackIDs.push(duplicate.id);
          if (backfillLocalImportSourceIdentity(duplicate, response.result.sourceIdentity)) await persist();
        }
        queueUpload(duplicate, response.result);
        continue;
      }
      const importedTrack = response.result.track;
      state.tracks.push(importedTrack);
      created.push(importedTrack);
      importedTrackIDs.push(importedTrack.id);
      existing.push({
        id: importedTrack.id,
        title: importedTrack.title,
        filePath: importedTrack.filePath,
        sourceSha256: importedTrack.sourceSha256 || null,
        contentSha256: importedTrack.contentSha256 || null,
      });
      if (!currentID) {
        currentID = importedTrack.id;
        state.currentTrackID = currentID;
        setPlaybackContext(tracksForActiveProfile(state), null);
      }
      await persist();
      queueUpload(importedTrack, response.result);
    }
    await saveImportedPlaylist();
    if (!cancelled && uploadQueue.length) {
      localImportBatchContext = null;
      const pendingUploads = await prepareLocalImportUploadBatch(uploadQueue, importContext);
      if (pendingUploads.length) {
        const uploadResult = await uploadLocalImportTracks(pendingUploads, importContext);
        uploadedCount = Number(uploadResult?.uploaded) || 0;
        uploadFailures.push(...(uploadResult?.failed || []));
        uploadCancelled = Boolean(uploadResult?.cancelled || serverTransferCancelRequested);
      }
      if (uploadedCount) scheduleServerCatalogRefresh(importContext);
    }
    if (created.length) {
      render();
      updateChrome();
    }
    const completed = created.length + duplicates;
    if (cancelled) {
      showNotice(`Playlist download cancelled after ${completed} of ${selected.length} ${mediaKind === "video" ? "videos" : "songs"}.`, "status");
      setLocalImportStage({ stage: "cancelled" });
    } else if (uploadCancelled) {
      showNotice(`Downloaded ${created.length} playlist ${mediaKind === "video" ? "video" : "song"}${created.length === 1 ? "" : "s"}. Server upload cancelled; every local file was kept.`, "status");
      setLocalImportStage({ stage: "cancelled" });
    } else if (failures.length) {
      const uploadText = formatServerUploadFailureNotice(uploadFailures);
      showNotice(`Downloaded ${created.length} of ${selected.length} playlist ${mediaKind === "video" ? "videos" : "songs"}; failed after retrying: ${failures.map((failure) => failure.title).join("; ")}.${uploadedCount ? ` Uploaded ${uploadedCount} successful song${uploadedCount === 1 ? "" : "s"}.` : ""}${uploadText ? ` ${uploadText}` : ""}`);
      setLocalImportStage({ stage: "failed" });
    } else {
      const duplicateText = duplicates ? ` ${duplicates} already on this device.` : "";
      const uploadedText = uploadedCount ? ` Uploaded ${uploadedCount} to ${importContext.profileName}.` : "";
      const uploadFailureNotice = formatServerUploadFailureNotice(uploadFailures);
      const uploadText = uploadFailureNotice ? ` ${uploadFailureNotice} The local files were kept.` : "";
      showNotice(`Downloaded ${created.length} playlist ${mediaKind === "video" ? "video" : "song"}${created.length === 1 ? "" : "s"}.${duplicateText}${uploadedText}${uploadText}`, uploadFailures.length ? "error" : "status");
      setLocalImportStage({ stage: uploadFailures.length ? "failed" : "complete" });
    }
  } catch (error) {
    try { await saveImportedPlaylist(); }
    catch (saveError) { console.error("Could not preserve the partially imported playlist", saveError); }
    if (created.length) {
      render();
      updateChrome();
    }
    showLocalImportError(error);
    setLocalImportStage({ stage: "failed" });
  } finally {
    if (importContext) releaseServerContext(importContext);
    localImportBatchContext = null;
    localImportRunning = false;
    setLocalImportOperationLocked(false);
    $("#cancelLocalImport").hidden = true;
    hideServerTransfer();
    serverTransferCancelRequested = false;
  }
}

async function requireCurrentServerUploadMode(requestedMode) {
  await refreshClientConfig({ force: true });
  const modes = currentServerTransferModes();
  if (modes.uploadMode !== requestedMode || !modes.available.upload.includes(requestedMode)) {
    throw { stage: "syncing", code: "MODE_DISABLED", message: "That upload mode is no longer enabled for this server and profile." };
  }
  return modes;
}

async function confirmServerSourceImport() {
  const requestedMode = localImportServerUploadMode;
  if (requestedMode !== "server_source_link") return false;
  const sourcePageURL = exactYouTubeSourcePageURL($("#localImportSource").value);
  if (!sourcePageURL) {
    throw { stage: "syncing", code: "SOURCE_PAGE_REQUIRED", message: "Server source import currently requires a canonical YouTube song page." };
  }
  const context = currentServerUploadContext();
  if (!context.adminToken.trim()) {
    throw { stage: "syncing", code: "ADMIN_KEY_REQUIRED", message: "Sign in to your Resonance account before importing a source link." };
  }
  reserveServerContext(context);
  const operation = localImportOperationSnapshot();
  localImportRunning = true;
  setLocalImportOperationLocked(true);
  try {
    await requireCurrentServerUploadMode(requestedMode);
    requireCurrentLocalImportOperation(operation);
    requireLocalImportServerContext(context);
    localImportKeepStateOnClose = true;
    $("#localImportDialog").close();
    updateServerTransfer({
      direction: "upload",
      owner: "local-import",
      title: "Importing source link",
      currentFile: "Preparing server import…",
      completed: 0,
      total: 1,
    });
    const response = await api.importServerSource({
      baseURL: context.serverURL,
      token: context.token || context.adminToken,
      adminToken: context.adminToken,
      profileID: context.profileID,
      mode: requestedMode,
      sourcePageURL,
    });
    requireLocalImportServerContext(context);
    const song = response?.song;
    if (!song?.id) throw new Error("The server imported the source but returned an invalid song record.");
    rememberUploadedServerSongs([{ remoteSong: song }]);
    serverConnectionText = `${response.status === "restored" ? "Restored" : "Imported"} ${song.title || "song"}`;
    showNotice(`${serverConnectionText} on ${context.profileName}.`, "status");
    setLocalImportStage({ stage: "complete" });
    scheduleServerCatalogRefresh(context);
    return true;
  } finally {
    releaseServerContext(context);
    localImportRunning = false;
    setLocalImportOperationLocked(false);
    hideServerTransfer("local-import");
  }
}

async function confirmLinkImport() {
  if (localImportRunning) return;
  if (!localImportResolution) return;
  const resolution = localImportResolution;
  const reviewedUpload = localImportServerUploadMode === "reviewed_match";
  if (reviewedUpload && resolution.kind?.endsWith("_playlist")) {
    showLocalImportError({ stage: "awaiting_selection", code: "PLAYLIST_UNSUPPORTED", message: "Reviewed-match upload accepts one explicitly selected song at a time." });
    return;
  }
  if (resolution.kind?.endsWith("_playlist")) {
    await confirmPlaylistImport();
    return;
  }
  const selected = document.querySelector('input[name="localImportCandidate"]:checked');
  const candidate = selected ? resolution.candidates[Number(selected.value)] : null;
  const mediaKind = resolution.mediaKind === "video" ? "video" : "audio";
  if (!candidate) {
    showLocalImportError({ stage: "awaiting_selection", message: `Choose one ${mediaKind} source to import.` });
    return;
  }
  if (reviewedUpload && candidate.serverBacked) {
    showLocalImportError({
      stage: "awaiting_selection",
      code: "REVIEWED_LOCAL_SOURCE_REQUIRED",
      message: "Choose a locally verifiable audio candidate for reviewed-match upload.",
    });
    return;
  }
  const uploadRequested = Boolean(localImportServerUploadMode) || $("#localImportSync").checked;
  if (reviewedUpload) $("#localImportSync").checked = true;
  const serverBacked = Boolean(candidate.serverBacked);
  const needsServerContext = localImportNeedsServerContext({ serverBacked, uploadRequested });
  const uploadConfigurationError = localImportUploadConfigurationError(serverBacked);
  if (uploadConfigurationError) {
    showLocalImportError(uploadConfigurationError);
    return;
  }
  let importContext = null;
  if (needsServerContext) {
    try { importContext = currentServerUploadContext(); }
    catch {
      showLocalImportError({ stage: "syncing", code: "SERVER_URL_REQUIRED", message: "Add a valid server URL before using this server-backed source." });
      return;
    }
  }
  const operation = localImportOperationSnapshot("localImportCandidate", { requiresResolvedSource: true });
  if (importContext) reserveServerContext(importContext);
  localImportRunning = true;
  setLocalImportOperationLocked(true);
  try {
    if (reviewedUpload) {
      await requireCurrentServerUploadMode("reviewed_match");
      requireCurrentLocalImportOperation(operation);
      if (importContext) requireLocalImportServerContext(importContext);
    }
    await stopLocalImportPreview({ release: true, resumeMain: true });
    requireCurrentLocalImportOperation(operation);
    if (importContext) requireLocalImportServerContext(importContext);
  } catch (error) {
    if (importContext) releaseServerContext(importContext);
    localImportRunning = false;
    setLocalImportOperationLocked(false);
    showLocalImportError(error);
    return;
  }
  $("#localImportError").hidden = true;
  $("#cancelLocalImport").hidden = false;
  setLocalImportStage({ stage: "inspecting_source", selected: candidate });
  serverTransferCancelRequested = false;
  updateLocalImportTransfer({ stage: "inspecting_source" });
  localImportKeepStateOnClose = true;
  $("#localImportDialog").close();
  try {
    const selectedMetadata = candidate.importMetadata || resolution.track;
    const metadata = {
      provider: selectedMetadata.provider || candidate.searchProvider || null,
      trackID: selectedMetadata.trackID || selectedMetadata.providerID || null,
      title: selectedMetadata.title,
      artist: selectedMetadata.artist,
      album: selectedMetadata.album,
      durationSeconds: selectedMetadata.durationSeconds,
      artworkURL: selectedMetadata.artworkURL || candidate.thumbnailURL,
      sourceURL: selectedMetadata.sourceURL || candidate.sourceURL,
      sourcePageURL: selectedMetadata.sourcePageURL || selectedMetadata.sourceURL || null,
    };
    const existing = state.tracks.map((track) => ({
      id: track.id,
      title: track.title,
      filePath: track.filePath,
      sourceSha256: track.sourceSha256 || null,
      contentSha256: track.contentSha256 || null,
    }));
    const response = candidate.serverBacked ? await api.startExternalImport({
      baseURL: importContext.serverURL,
      adminToken: importContext.adminToken,
      profileID: importContext.profileID,
      sourceURL: candidate.sourceURL,
      sourceIdentity: localImportSourceIdentity(candidate, metadata),
      resumeSelection: candidate.sourceProvider === "torbox_file",
      fileID: candidate.fileID,
      metadata,
      existing,
    }) : await api.startLocalImport({
      sourceURL: candidate.sourceURL,
      sourceIdentity: localImportSourceIdentity(candidate, metadata),
      mediaKind,
      metadata,
      existing,
    });
    if (!response?.ok) throw response?.error || { stage: "saving_local", message: "The local song could not be saved." };
    if (importContext) requireLocalImportServerContext(importContext);
    if (response.result.kind === "selection_required") {
      resolution.candidates = response.result.files.map((file) => ({
        title: file.name,
        artist: "",
        album: resolution.track.album,
        durationSeconds: null,
        thumbnailURL: resolution.track.artworkURL,
        sourceProvider: "torbox_file",
        sourceKind: "server_file",
        sourceURL: null,
        fileID: file.id,
        size: file.size,
        contentType: file.contentType,
        confidence: "file",
        sourceIdentity: localImportSourceIdentity(candidate, metadata),
        serverBacked: true,
      }));
      renderLocalImportResolution();
      setLocalImportStage({ stage: "awaiting_selection" });
      hideServerTransfer("local-import");
      serverTransferCancelRequested = false;
      $("#localImportDialog").showModal();
      return;
    }
    let importedTrack = null;
    if (response.result.kind === "duplicate") {
      importedTrack = state.tracks.find((track) => track.id === response.result.trackID) || null;
      if (backfillLocalImportSourceIdentity(importedTrack, response.result.sourceIdentity)) await persist();
      setLocalImportStage({ stage: "local_complete" });
      showNotice(importedTrack ? `${importedTrack.title} is already in this device library.` : `This ${mediaKind} is already in the device library.`, "status");
    } else {
      importedTrack = response.result.track;
      state.tracks.push(importedTrack);
      if (!currentID) {
        currentID = importedTrack.id;
        state.currentTrackID = currentID;
        setPlaybackContext(tracksForActiveProfile(state), null);
      }
      await persist();
      render();
      updateChrome();
      setLocalImportStage({ stage: "local_complete" });
      showNotice(response.result.serverBacked
        ? `Imported ${importedTrack.title} on this device and ${importContext.profileName}.`
        : `${mediaKind === "video" ? "Downloaded" : "Imported"} ${importedTrack.title} on this device.`, "status");
    }

    if (response.result.serverBacked && response.result.remoteSong && importedTrack) {
      requireTrackUploadAssociationContext(importedTrack, importContext);
      rememberUploadedServerSongs([{ remoteSong: response.result.remoteSong }]);
      if (reconcileUploadedTrack(state, importedTrack.id, response.result.remoteSong, {
        serverURL: importContext.serverURL,
        profileID: importContext.profileID,
      })) {
        playlistMutationGeneration += 1;
        await persist({ refreshSidebar: false });
        requireLocalImportServerContext(importContext);
        schedulePlaylistSync();
      }
    }

    if (!response.result.serverBacked && uploadRequested && importedTrack?.filePath) {
      setLocalImportStage({ stage: "syncing", profileID: importContext.profileID });
      const uploaded = reviewedUpload
        ? await uploadReviewedMatchTrack(importedTrack, importContext)
        : await uploadImportedTrackWithMode(
            importedTrack,
            importContext,
            localImportServerUploadMode === "server_source_link" ? "server_source_link" : "local_file",
          );
      if (!uploaded?.ok) {
        showLocalImportError(uploaded?.error || {
          stage: "syncing",
          message: reviewedUpload
            ? "The reviewed song was saved locally, but its verified-byte upload failed."
            : "The song was saved locally, but its optional profile upload failed.",
        });
        return;
      }
      scheduleServerCatalogRefresh(importContext);
      showNotice(uploaded.skipped
        ? `${importedTrack.title} is already on ${importContext.profileName}.`
        : `Uploaded ${importedTrack.title} to ${importContext.profileName}.`, "status");
    }
    setLocalImportStage({ stage: "complete" });
    $("#confirmLocalImport").hidden = true;
    $("#cancelLocalImport").hidden = true;
    $("#localImportSyncRow").hidden = true;
    $("#chooseLocalFiles").title = "Import another file";
    $("#chooseLocalFiles").setAttribute("aria-label", "Import another file");
  } catch (error) {
    showLocalImportError(error);
  } finally {
    if (importContext) releaseServerContext(importContext);
    localImportRunning = false;
    setLocalImportOperationLocked(false);
    if ($("#localImportStage").dataset.stage !== "downloading") $("#cancelLocalImport").hidden = true;
    hideServerTransfer("local-import");
    serverTransferCancelRequested = false;
  }
}

async function cancelLinkImport() {
  if (!localImportRunning) return;
  localImportInteractionGeneration += 1;
  $("#cancelLocalImport").disabled = true;
  try { await api.cancelLocalImport(); }
  finally {
    $("#cancelLocalImport").disabled = false;
    setLocalImportStage({ stage: "cancelled" });
  }
}

async function closeLocalImport() {
  localImportInteractionGeneration += 1;
  await stopLocalImportPreview({ release: true, resumeMain: true });
  if (localImportRunning) await api.cancelLocalImport();
  $("#localImportDialog").close();
}

function renderAddSongsDialog() {
  const playlist = state.playlists.find((item) => item.id === addSongsPlaylistID);
  if (!playlist) {
    $("#addSongsDialog").close();
    return;
  }
  $("#addSongsPlaylistName").textContent = playlist.name;
  const query = $("#addSongsSearch").value.trim().toLocaleLowerCase();
  const tracks = tracksForActiveProfile(state).filter((track) =>
    `${track.title || ""} ${track.artist || ""} ${track.album || ""}`.toLocaleLowerCase().includes(query));
  $("#addSongsList").innerHTML = tracks.length ? tracks.map((track) => {
    const added = playlist.isSystem ? state.favorites.includes(track.id) : playlist.trackIDs.includes(track.id);
    const title = track.title || "Untitled";
    return `<div class="add-song-row">${artwork(track)}<div><strong>${escapeHTML(title)}</strong><small>${escapeHTML(track.artist || "Local file")}</small></div><button class="${added ? "added" : ""}" data-add-song="${escapeHTML(track.id)}" aria-label="${added ? "Remove" : "Add"} ${escapeHTML(title)}">${added ? checkIcon : plusIcon}</button></div>`;
  }).join("") : `<div class="add-songs-empty"><b>No matching songs</b><span>Try a different title, artist, or album.</span></div>`;
}

function openAddSongsDialog(playlist) {
  addSongsPlaylistID = playlist.id;
  $("#addSongsSearch").value = "";
  renderAddSongsDialog();
  $("#addSongsDialog").showModal();
  requestAnimationFrame(() => $("#addSongsSearch").focus());
}

function updateServerTransfer({ direction, currentFile, completed = 0, total = 1, owner = "server", title = null, autoHide = true }) {
  if (serverTransferCancelRequested && serverTransferOwner === owner) return;
  const toast = $("#serverTransferToast");
  if (!toast) return;
  const ratio = total ? Math.min(1, completed / total) : 0;
  serverTransferActive = true;
  serverTransferOwner = owner;
  toast.hidden = false;
  toast.dataset.direction = direction;
  $("#serverTransferIcon").innerHTML = direction === "upload" ? serverUploadIcon : serverDownloadIcon;
  $("#serverTransferTitle").textContent = title || (direction === "upload" ? "Uploading" : "Downloading");
  $("#serverTransferDetail").textContent = currentFile || "Preparing transfer…";
  $("#serverTransferProgress").value = ratio;
  $("#serverTransferPercent").textContent = `${Math.round(ratio * 100)}%`;
  if (autoHide && total > 0 && completed >= total) hideServerTransfer(owner);
}

function hideServerTransfer(owner = null) {
  if (owner && serverTransferOwner && owner !== serverTransferOwner) return;
  const toast = $("#serverTransferToast");
  if (toast) toast.hidden = true;
  const cancel = $("#dismissServerTransfer");
  if (cancel) cancel.disabled = false;
  serverTransferActive = false;
  serverTransferOwner = null;
}

async function cancelServerTransfer() {
  if (!serverTransferActive || serverTransferCancelRequested) return;
  const owner = serverTransferOwner;
  serverTransferCancelRequested = true;
  $("#serverTransferDetail").textContent = "Cancelling transfer…";
  $("#dismissServerTransfer").disabled = true;
  try {
    if (owner === "local-import") await api.cancelLocalImport();
    else await api.cancelServerTransfer();
  } finally {
    hideServerTransfer(owner);
  }
}

function localImportTransferName() {
  if (localImportBatchContext) return `${localImportBatchContext.index + 1} of ${localImportBatchContext.total} • ${localImportBatchContext.title}`;
  return localImportResolution?.track?.title
    || localImportResolution?.candidates?.[0]?.title
    || (selectedLocalImportMediaKind() === "video" ? "Video import" : "Audio import");
}

function updateLocalImportTransfer(value = {}) {
  const stage = value.stage || "inspecting_source";
  setLocalImportStage(value);
  if ($("#localImportDialog").open) return;
  if (["idle", "resolving_metadata", "searching_candidates", "awaiting_selection", "failed", "cancelled"].includes(stage)) return;
  const currentFile = value.currentFile || localImportTransferName();
  const completed = Number(value.completed) || 0;
  const total = Number(value.total) || 0;
  const uploadComplete = stage === "complete"
    && serverTransferOwner === "local-import"
    && $("#serverTransferToast")?.dataset.direction === "upload";
  if (stage === "syncing" || uploadComplete) {
    updateServerTransfer({
      direction: "upload",
      owner: "local-import",
      title: uploadComplete ? "Upload complete" : "Uploading",
      currentFile,
      completed: uploadComplete && !total ? 1 : completed,
      total: total || 1,
      autoHide: false,
    });
    return;
  }
  const titles = {
    preparing_external: "Preparing download",
    waiting_external: "Preparing download",
    inspecting_source: "Preparing download",
    downloading: "Downloading",
    processing: "Processing download",
    saving_local: "Saving download",
    local_complete: "Download complete",
    complete: "Import complete",
  };
  const determinateComplete = ["processing", "saving_local", "local_complete", "complete"].includes(stage);
  updateServerTransfer({
    direction: "download",
    owner: "local-import",
    title: titles[stage] || "Importing",
    currentFile,
    completed: determinateComplete && !total ? 1 : completed,
    total: determinateComplete && !total ? 1 : (total || 1),
    autoHide: false,
  });
}

async function serverAction(mode) {
  if (serverConnectInFlight) {
    serverConnectPending = true;
    return;
  }
  const status = $("#serverStatus");
  try {
    await saveServerForm();
  } catch (error) {
    showNotice(error.message || "The server connection cannot change during a transfer.");
    return;
  }
  if (mode !== "catalog" && currentServerTransferModes().downloadMode !== "verified_file_cache") {
    showNotice("Offline downloads are disabled by the signed server configuration. Choose a song to play it directly from the server.");
    if (section === "server") renderServer();
    return;
  }
  const context = currentProfileContext();
  const catalogRequestGeneration = serverCatalogGeneration;
  serverConnectInFlight = true;
  if (mode !== "catalog") {
    serverTransferCancelRequested = false;
    updateServerTransfer({ direction: "download", currentFile: "Preparing download…", completed: 0, total: 1 });
  }
  serverConnectionText = mode === "catalog" ? "Connecting…" : "Syncing downloads…";
  if (status) status.textContent = serverConnectionText;
  let transferCancelled = false;
  try {
    let catalog;
    if (mode !== "catalog") {
      const songIDs = mode === "selected" ? [...selectedRemoteIDs] : null;
      if (mode === "selected" && !songIDs.length) throw new Error("Select one or more songs first.");
      const result = await api.syncServer({ baseURL: context.serverURL, token: context.token, profileID: context.profileID, existing: state.tracks, songIDs });
      if (!profileContextIsCurrent(context)) return;
      catalog = result.catalog;
      transferCancelled = Boolean(result.cancelled || serverTransferCancelRequested);
      mergeSyncedTracks(state, result);
      const failedDownloads = Array.isArray(result.failed) ? result.failed : [];
      serverConnectionText = transferCancelled
        ? `Download cancelled${result.downloaded.length ? ` • ${result.downloaded.length} completed` : ""}`
        : failedDownloads.length
          ? `Downloaded ${result.downloaded.length} song${result.downloaded.length === 1 ? "" : "s"} • ${failedDownloads.length} failed`
          : `Synced ${result.downloaded.length} new song${result.downloaded.length === 1 ? "" : "s"}`;
      if (!transferCancelled && failedDownloads.length) {
        showNotice(formatServerDownloadFailureNotice(failedDownloads));
      }
      selectedRemoteIDs.clear();
      if (mode === "selected") serverSelecting = false;
      await persist();
    } else {
      catalog = await api.fetchCatalog({ baseURL: context.serverURL, token: context.token, profileID: context.profileID });
      if (!catalogRequestCanApply({
        requestGeneration: catalogRequestGeneration,
        currentGeneration: serverCatalogGeneration,
        contextCurrent: profileContextIsCurrent(context),
      })) return;
      serverConnectionText = `Connected • ${catalog.count} song${catalog.count === 1 ? "" : "s"}`;
    }
    if (catalog) {
      replaceServerCatalog(catalog.songs);
      serverConnected = true;
      hydrateServerCatalogArtwork(serverCatalog);
    }
    await persist();
    renderSidebar();
    if (!transferCancelled) schedulePlaylistSync();
  } catch (error) {
    if (!profileContextIsCurrent(context)) return;
    if (mode === "catalog" && !catalogRequestCanApply({
      requestGeneration: catalogRequestGeneration,
      currentGeneration: serverCatalogGeneration,
    })) return;
    serverConnectionText = serverTransferCancelRequested ? "Download cancelled" : friendlyIPCError(error, "Connection failed");
    serverConnected = false;
    replaceServerCatalog([]);
    selectedRemoteIDs.clear();
    serverSelecting = false;
    if (!serverTransferCancelRequested) showNotice(serverConnectionText);
  } finally {
    serverConnectInFlight = false;
    if (mode !== "catalog") {
      hideServerTransfer("server");
      serverTransferCancelRequested = false;
    }
    if (section === "server") renderServer();
    if (serverConnectPending) {
      serverConnectPending = false;
      queueMicrotask(() => serverAction("catalog"));
    }
  }
}

async function uploadServerSongs() {
  if (serverUploadBlockedByActivity({ transferActive: serverTransferActive || Boolean(serverContextReservation) })) return;
  await saveServerForm();
  if (serverUploadBlockedByActivity({ transferActive: serverTransferActive || Boolean(serverContextReservation) })) return;
  const uploadMode = currentServerTransferModes().uploadMode;
  if (["local_file", "server_source_link", "reviewed_match"].includes(uploadMode)) {
    openLocalImport({ serverUploadMode: uploadMode });
    return;
  }
  if (uploadMode !== "local_file") {
    showNotice("Uploads are disabled by the signed server configuration.");
    return;
  }
  const configurationError = serverUploadConfigurationError({ serverURL: state.serverURL, adminToken: serverAdminToken });
  if (configurationError) {
    showNotice(configurationError);
    return;
  }
  const context = currentServerUploadContext();
  const status = $("#serverStatus");
  serverTransferCancelRequested = false;
  updateServerTransfer({ direction: "upload", currentFile: "Choose songs to upload…", completed: 0, total: 1 });
  try {
    const result = await api.uploadServer({
      baseURL: context.serverURL,
      adminToken: context.adminToken,
      profileID: context.profileID,
      associationConflictPaths: remoteAssociationConflictFilePaths(state.tracks, context),
    });
    if (!serverUploadContextIsCurrent(context)) return;
    if (result.selectionCancelled) {
      serverConnectionText = "No files selected";
      if (status) status.textContent = serverConnectionText;
      return;
    }
    rememberUploadedServerSongs(result.results);
    await retainServerUploadManifest(result, context, "picker");
    const failedUploads = Array.isArray(result.failed) ? result.failed : [];
    const failureNotice = formatServerUploadFailureNotice(failedUploads);
    const cancelled = Boolean(result.cancelled || serverTransferCancelRequested);
    serverConnectionText = cancelled
      ? `Upload cancelled${result.uploaded ? ` • ${result.uploaded} completed` : ""}`
      : failedUploads.length
        ? `Uploaded ${result.uploaded} song${result.uploaded === 1 ? "" : "s"} • ${failedUploads.length} failed`
        : `Uploaded ${result.uploaded} song${result.uploaded === 1 ? "" : "s"}`;
    if (status) status.textContent = serverConnectionText;
    if (!cancelled && failureNotice) showNotice(failureNotice);
    else if (!cancelled && result.uploaded) showNotice(serverConnectionText, "status");
    if (result.uploaded) scheduleServerCatalogRefresh(context);
  } catch (error) {
    if (!serverUploadContextIsCurrent(context)) return;
    serverConnectionText = serverTransferCancelRequested ? "Upload cancelled" : friendlyIPCError(error, "Upload failed");
    if (status) status.textContent = serverConnectionText;
    if (!serverTransferCancelRequested) showNotice(serverConnectionText);
  } finally {
    hideServerTransfer("server");
    serverTransferCancelRequested = false;
  }
}

async function uploadMissingDownloadedSongs() {
  if (serverUploadBlockedByActivity({ transferActive: serverTransferActive || Boolean(serverContextReservation) })) return;
  await saveServerForm();
  if (serverUploadBlockedByActivity({ transferActive: serverTransferActive || Boolean(serverContextReservation) })) return;
  if (currentServerTransferModes().uploadMode !== "local_file") {
    showNotice("Uploading downloaded songs is available only in Local files upload mode.");
    return;
  }
  const configurationError = serverUploadConfigurationError({ serverURL: state.serverURL, adminToken: serverAdminToken });
  if (configurationError) {
    showNotice(configurationError);
    return;
  }
  const context = currentServerUploadContext();
  const status = $("#serverStatus");
  serverTransferCancelRequested = false;
  updateServerTransfer({ direction: "upload", currentFile: "Checking downloaded songs…", completed: 0, total: 1 });
  try {
    const plan = planMissingDownloadedUploads(state, serverCatalog);
    for (const match of plan.matches) {
      reconcileUploadedTrack(state, match.trackID, match.remoteSong, {
        serverURL: context.serverURL,
        profileID: context.profileID,
      });
    }
    if (plan.matches.length) {
      await persist();
      schedulePlaylistSync();
    }
    const checkedCount = plan.alreadyPresent.length
      + plan.matches.length
      + plan.uploadTracks.length
      + plan.ambiguous.length
      + plan.missingSource.length;
    const catalogMatchCount = plan.alreadyPresent.length + plan.matches.length;
    const reviewCount = plan.ambiguous.length + plan.missingSource.length;
    const reviewNotices = [
      plan.ambiguous.length
        ? `${plan.ambiguous.length} metadata-only match${plan.ambiguous.length === 1 ? "" : "es"} cannot be associated automatically.`
        : "",
      plan.missingSource.length
        ? `${plan.missingSource.length} downloaded song${plan.missingSource.length === 1 ? " has" : "s have"} no preserved HTTPS source link.`
        : "",
    ].filter(Boolean);
    if (!plan.uploadTracks.length) {
      serverConnectionText = checkedCount === 0
        ? "No link-downloaded songs are available to upload"
        : reviewCount
          ? `Checked ${checkedCount} downloaded song${checkedCount === 1 ? "" : "s"} • ${catalogMatchCount} already on the server • ${reviewCount} ${reviewCount === 1 ? "needs" : "need"} review`
          : `Checked ${checkedCount} downloaded song${checkedCount === 1 ? "" : "s"} • all already on the server`;
      if (status) status.textContent = serverConnectionText;
      showNotice(reviewNotices.length ? `${serverConnectionText}. ${reviewNotices.join(" ")}` : serverConnectionText, reviewNotices.length ? "error" : "status");
      if (section === "server") renderServer();
      return;
    }
    const result = await api.uploadServer({
      baseURL: context.serverURL,
      adminToken: context.adminToken,
      profileID: context.profileID,
      files: plan.uploadTracks.map((track) => ({
        trackID: track.id,
        filePath: track.filePath,
        title: track.title,
        artist: track.artist,
        album: track.album,
        duration: Number(track.duration) || 0,
        artworkURL: track.artworkURL || null,
        mediaSourceURL: preservedUploadSourceURL(track),
        mediaKind: isInstalledVideoTrack(track) ? "video" : "audio",
      })),
    });
    if (!serverUploadContextIsCurrent(context)) return;
    rememberUploadedServerSongs(result.results);
    for (const uploaded of result.results || []) {
      reconcileUploadedTrack(state, uploaded.trackID, uploaded.remoteSong, {
        serverURL: context.serverURL,
        profileID: context.profileID,
      });
    }
    await retainServerUploadManifest(result, context, "missing-downloads");
    const failureNotice = formatServerUploadFailureNotice(result.failed);
    const reviewNotice = reviewNotices.join(" ");
    const duplicateCount = Math.max(0, Math.min(result.uploaded, Number(result.duplicates) || 0));
    const createdCount = Math.max(0, result.uploaded - duplicateCount);
    const alreadyCount = catalogMatchCount + duplicateCount;
    const cancelled = Boolean(result.cancelled || serverTransferCancelRequested);
    if (cancelled) {
      serverConnectionText = `Upload cancelled${result.uploaded ? ` • ${result.uploaded} completed` : ""}`;
    } else if (failureNotice) {
      serverConnectionText = `Checked ${checkedCount} • uploaded ${createdCount} • ${alreadyCount} already on the server • ${(result.failed || []).length} failed`;
      showNotice(`${failureNotice}${reviewNotice ? ` ${reviewNotice}` : ""}`);
    } else {
      serverConnectionText = `Checked ${checkedCount} • uploaded ${createdCount} • ${alreadyCount} already on the server`;
      showNotice(`${serverConnectionText}.${reviewNotice ? ` ${reviewNotice}` : ""}`, reviewNotice ? "error" : "status");
    }
    if (status) status.textContent = serverConnectionText;
    serverConnected = true;
    if (section === "server") renderServer();
    if ((result.results || []).length) {
      schedulePlaylistSync();
      scheduleServerCatalogRefresh(context);
    }
  } catch (error) {
    if (!serverUploadContextIsCurrent(context)) return;
    serverConnectionText = serverTransferCancelRequested ? "Upload cancelled" : friendlyIPCError(error, "Upload failed");
    if (status) status.textContent = serverConnectionText;
    if (!serverTransferCancelRequested) showNotice(serverConnectionText);
  } finally {
    hideServerTransfer("server");
    serverTransferCancelRequested = false;
  }
}

async function requestPlayback() {
  try {
    await audio.play();
    synchronizeInstalledVideoWithAudio({ forceSeek: true });
  } catch (error) {
    if (error?.name === "AbortError") return;
    updateChrome();
    showNotice(error.message ? `Could not play this song: ${error.message}` : "Resonance could not play this song.");
  }
}

function activeClipRange(track = currentTrack()) {
  return track ? playbackRangeForTrack(state, track) : null;
}

function clippedPlaybackPosition(value, track = currentTrack()) {
  const range = activeClipRange(track);
  const position = Math.max(0, Number(value) || 0);
  return range ? Math.max(range.startSeconds, Math.min(position, range.endSeconds)) : position;
}

function enforceCurrentClipRange() {
  const range = activeClipRange();
  if (!range || (audio.currentTime >= range.startSeconds && audio.currentTime < range.endSeconds)) return;
  audio.currentTime = range.startSeconds;
  state.position = range.startSeconds;
}

function finishClipPlaybackIfNeeded() {
  const track = currentTrack();
  const range = activeClipRange(track);
  if (!track || !range || audio.currentTime + 0.02 < range.endSeconds || clipBoundaryTrackID === track.id) return false;
  clipBoundaryTrackID = track.id;
  updateListeningSession();
  scheduleListeningHistorySync();
  if (repeat) {
    finishListeningSessionForReplay();
    audio.currentTime = range.startSeconds;
    state.position = range.startSeconds;
    void requestPlayback();
    synchronizeInstalledVideoWithAudio({ forceSeek: true });
  } else if (!move(1)) {
    audio.pause();
    audio.currentTime = range.endSeconds;
    state.position = range.endSeconds;
    persistInBackground({ refreshSidebar: false });
    updateChrome();
  }
  queueMicrotask(() => { clipBoundaryTrackID = null; });
  return true;
}

function play(track, queue = null, options = {}) {
  if (!track) return;
  if (track.available === false || track.missing) {
    showNotice(`${track.title || "This song"} is still in your library, but its file is unavailable on this device.`);
    return;
  }
  const {
    recordHistory = true,
    playlistID = activePlaybackPlaylistID,
    autoplay = true,
  } = options;
  if (Array.isArray(queue) && queue.length) setPlaybackContext(queue, playlistID, track.id);
  else if (!activePlaybackQueueIDs.includes(track.id)) setPlaybackContext(tracksForActiveProfile(state), null, track.id);
  if (recordHistory
      && currentID
      && currentID !== track.id
      && state.tracks.some((candidate) => candidate.id === currentID)) history.push(currentID);
  if (activeListeningEntryID) {
    updateListeningSession();
    persistInBackground();
    scheduleListeningHistorySync();
  }
  activeListeningEntryID = null;
  lastListeningPosition = 0;
  lastPersistedListeningSeconds = 0;
  if (activeServerStream && track.id !== activeServerStream.track.id) {
    releaseActiveServerStream({ stopPlayback: false });
  }
  currentID = track.id;
  state.currentTrackID = track.transientStream ? null : currentID;
  const range = playbackRangeForTrack(state, track);
  state.position = range?.startSeconds ?? 0;
  pendingRestorePosition = state.position;
  setAudioSource(track);
  audio.volume = playbackGainForVolume(state.volume);
  audio.playbackRate = Number($("#speed").value) || 1;
  if (autoplay) void requestPlayback();
  persistInBackground(); updateChrome(); render();
}

function toggle() {
  const track = currentTrack();
  if (!track) {
    const firstTrack = tracksForActiveProfile(state).find((candidate) => candidate.available !== false);
    if (firstTrack) play(firstTrack);
    return;
  }
  if (!audio.currentSrc && !audio.src) { play(track); return; }
  if (audio.paused) {
    const range = activeClipRange(track);
    if (range && (audio.currentTime < range.startSeconds || audio.currentTime >= range.endSeconds)) {
      audio.currentTime = range.startSeconds;
      state.position = range.startSeconds;
    }
    void requestPlayback();
  } else audio.pause();
  updateChrome();
}

function move(direction, recordHistory = direction > 0) {
  if (currentTrack()?.transientStream) return false;
  const tracks = activePlaybackTracks();
  const index = nextIndex(tracks, currentID, direction);
  if (index < 0) return false;
  play(tracks[index], null, { recordHistory });
  return true;
}

function previous() {
  if (currentTrack()?.transientStream) return;
  const range = activeClipRange();
  const start = range?.startSeconds ?? 0;
  if (audio.currentTime > start + 3) {
    audio.currentTime = start;
    state.position = start;
    return;
  }
  const previousID = history.pop();
  const track = previousID && state.tracks.find((item) => item.id === previousID && trackBelongsToActiveProfile(state, item));
  if (track) play(track, null, { recordHistory: false });
  else move(-1, false);
}

function toggleFavorite(id) {
  const track = state.tracks.find((item) => item.id === id && trackBelongsToActiveProfile(state, item));
  if (!track) return;
  const willLike = !state.favorites.includes(id);
  state.favorites = willLike ? [...state.favorites, id] : state.favorites.filter((item) => item !== id);
  if (track?.remoteID) {
    likesMutationGeneration += 1;
    state.remoteLikedSongIDs = willLike
      ? [...new Set([...state.remoteLikedSongIDs, track.remoteID])]
      : state.remoteLikedSongIDs.filter((remoteID) => remoteID !== track.remoteID);
    state.dirtyRemoteLikeSongIDs = [...new Set([...state.dirtyRemoteLikeSongIDs, track.remoteID])];
    state.likesDirty = true;
  }
  persistInBackground(); schedulePlaylistSync(); render(); updateChrome();
}

function newPlaylist(trackID = null) {
  pendingPlaylistTrackID = typeof trackID === "string" ? trackID : null;
  const dialog = $("#playlistDialog");
  $("#playlistName").value = "";
  $("#createPlaylist").disabled = true;
  dialog.showModal();
  requestAnimationFrame(() => $("#playlistName").focus());
}

function renderSidebar() {
  normalizeState(state);
  $("#sidebarPlaylists").innerHTML = state.playlists.map((playlist) => `<button data-side-playlist="${escapeHTML(playlist.id)}" aria-keyshortcuts="Shift+F10">${playlistArtworkMarkup(playlist, { className: "playlist-sidebar-art", tagName: "span" })}<div><strong>${escapeHTML(playlist.name)}</strong><small>${playlist.trackIDs.length} tracks</small></div></button>`).join("");
  document.querySelectorAll("[data-side-playlist]").forEach((button) => {
    button.onclick = () => navigate("library", button.dataset.sidePlaylist);
    button.oncontextmenu = (event) => openPlaylistContextMenu(event, button.dataset.sidePlaylist);
    button.onkeydown = (event) => {
      if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) {
        event.preventDefault();
        openPlaylistContextMenu(event, button.dataset.sidePlaylist);
      }
    };
  });
}

function renderQueue() {
  if (!$("#queue")) return;
  const tracks = activePlaybackTracks();
  const index = tracks.findIndex((track) => track.id === currentID);
  const queue = index < 0 ? tracks : tracks.slice(index + 1);
  $("#queue").innerHTML = queue.slice(0, 12).map((track) => `<button data-queue="${escapeHTML(track.id)}">${artwork(track)}<span><strong>${escapeHTML(track.title)}</strong><small>${escapeHTML(track.artist)}</small></span><time>${formatTime(track.duration)}</time></button>`).join("") || `<div class="empty"><span>Queue is empty</span></div>`;
  document.querySelectorAll("[data-queue]").forEach((button) => button.onclick = () => play(state.tracks.find((track) => track.id === button.dataset.queue && trackBelongsToActiveProfile(state, track))));
}

function fullPlayerQueueTracks() {
  const tracks = activePlaybackTracks();
  const index = tracks.findIndex((track) => track.id === currentID);
  return index < 0 ? tracks : tracks.slice(index + 1);
}

function fullPlayerHistoryTracks() {
  const profileID = activeProfileID();
  const serverOrigin = normalizedServerOrigin(state.serverURL);
  const activeTracks = tracksForActiveProfile(state);
  const scopedHistory = [...state.listeningHistory]
    .filter((entry) =>
      (entry.profileID || "default") === profileID
      && normalizedServerOrigin(entry.serverOrigin) === serverOrigin
      && entry.id !== activeListeningEntryID);
  const syncedHistory = scopedHistory
    .filter((entry) => listeningHistoryEntryQualifiesAsPlay(state, entry))
    .sort((left, right) => Date.parse(right.startedAt) - Date.parse(left.startedAt))
    .map((entry) => {
      const track = activeTracks.find((item) => item.id === entry.trackID)
        || activeTracks.find((item) => entry.remoteID && item.remoteID === entry.remoteID && (item.syncProfileID || "default") === profileID);
      return track || {
        id: entry.trackID,
        remoteID: entry.remoteID,
        title: entry.title || "Unknown song",
        artist: entry.artist || "Unknown artist",
        album: entry.album || "Unknown Album",
        duration: Number(entry.duration) || 0,
        artwork: null,
        historyOnly: true,
      };
    });
  if (scopedHistory.length) return syncedHistory;
  const tracksByID = new Map(tracksForActiveProfile(state).map((track) => [track.id, track]));
  return [...history].reverse().map((trackID) => tracksByID.get(trackID)).filter(Boolean);
}

function renderFullPlayerQueue() {
  const queue = fullPlayerQueueTab === "history" ? fullPlayerHistoryTracks() : fullPlayerQueueTracks();
  const count = queue.length;
  $("#fullPlayerQueueCount").textContent = `${count} ${count === 1 ? "song" : "songs"}`;
  document.querySelectorAll("[data-full-player-queue-tab]").forEach((button) => {
    const active = button.dataset.fullPlayerQueueTab === fullPlayerQueueTab;
    button.classList.toggle("active", active);
    button.setAttribute("aria-selected", String(active));
    button.tabIndex = active ? 0 : -1;
  });
  $("#fullPlayerQueue").setAttribute("aria-labelledby", fullPlayerQueueTab === "history" ? "fullPlayerQueueHistoryTab" : "fullPlayerQueueUpNextTab");
  $("#fullPlayerQueue").innerHTML = queue.length ? queue.map((track) => `<button class="full-player-queue-item" type="button" data-full-player-queue="${escapeHTML(track.id)}" aria-label="${track.historyOnly ? "Not downloaded: " : "Play "}${escapeHTML(track.title || "Untitled")} by ${escapeHTML(track.artist || "Unknown Artist")}" ${track.historyOnly ? "disabled" : ""}>
    ${artwork(track)}<span><strong>${escapeHTML(track.title || "Untitled")}</strong><small>${escapeHTML(track.artist || "Unknown Artist")}</small></span><time>${track.historyOnly ? "Not downloaded" : formatTime(track.duration)}</time>
  </button>`).join("") : `<div class="full-player-queue-empty"><span>${fullPlayerQueueTab === "history" ? "Nothing played yet." : "Nothing else is queued."}</span></div>`;
  document.querySelectorAll("[data-full-player-queue]").forEach((button) => {
    button.onclick = () => play(state.tracks.find((track) => track.id === button.dataset.fullPlayerQueue && trackBelongsToActiveProfile(state, track)));
  });
}

function updateFullPlayerProgress() {
  const elapsed = Number(audio.currentTime) || 0;
  const duration = currentPlaybackDuration();
  const seek = $("#fullPlayerSeek");
  $("#fullPlayerElapsed").textContent = formatTime(elapsed);
  $("#fullPlayerDuration").textContent = formatTime(duration);
  seek.value = duration ? String(Math.round(elapsed / duration * 1000)) : "0";
  seek.setAttribute("aria-valuetext", `${formatTime(elapsed)} of ${formatTime(duration)}`);
  paintRange(seek);
}

function updatePlaybackProgressUI() {
  const elapsed = Number(audio.currentTime) || 0;
  const duration = currentPlaybackDuration();
  $("#elapsed").textContent = formatTime(elapsed);
  $("#duration").textContent = formatTime(duration);
  $("#seek").value = duration ? String(Math.round(elapsed / duration * 1000)) : "0";
  $("#seek").setAttribute("aria-valuetext", `${formatTime(elapsed)} of ${formatTime(duration)}`);
  paintRange($("#seek"));
  updateFullPlayerProgress();
}

function stopPlaybackProgressAnimation() {
  if (!playbackProgressAnimationFrame) return;
  cancelAnimationFrame(playbackProgressAnimationFrame);
  playbackProgressAnimationFrame = null;
}

function animatePlaybackProgress() {
  playbackProgressAnimationFrame = null;
  updatePlaybackProgressUI();
  if (!audio.paused && !audio.ended) {
    playbackProgressAnimationFrame = requestAnimationFrame(animatePlaybackProgress);
  }
}

function startPlaybackProgressAnimation() {
  if (playbackProgressAnimationFrame || audio.paused || audio.ended) return;
  playbackProgressAnimationFrame = requestAnimationFrame(animatePlaybackProgress);
}

function setAudioSource(track) {
  audioSourceTrackID = track?.id || null;
  audioMetadataTrackID = null;
  audio.src = track?.fileUrl || "";
}

function currentPlaybackDuration(track = currentTrack()) {
  const storedDuration = Number(track?.duration) || 0;
  if (!track || audioMetadataTrackID !== track.id) return storedDuration;
  if (isInstalledVideoTrack(track) && storedDuration > 0) return storedDuration;
  return Number(audio.duration) || storedDuration;
}

function syncFullPlayerTitleMarquee() {
  const viewport = $("#fullPlayerTitle");
  const track = $("#fullPlayerTitleTrack");
  const text = $("#fullPlayerTitleText");
  if (fullPlayerTitleMarqueeFrame) cancelAnimationFrame(fullPlayerTitleMarqueeFrame);
  viewport.classList.remove("overflowing");
  track.style.removeProperty("--full-player-title-cycle");
  track.style.removeProperty("--full-player-title-duration");

  fullPlayerTitleMarqueeFrame = requestAnimationFrame(() => {
    fullPlayerTitleMarqueeFrame = null;
    if (!$("#nowPlayingDialog").open) return;
    const metrics = titleMarqueeMetrics(text.getBoundingClientRect().width, viewport.clientWidth);
    if (metrics.travel <= 1) return;
    track.style.setProperty("--full-player-title-cycle", `${metrics.cycleDistance}px`);
    track.style.setProperty("--full-player-title-duration", `${metrics.durationSeconds}s`);
    viewport.classList.add("overflowing");
  });
}

function setFullPlayerTitle(title) {
  const viewport = $("#fullPlayerTitle");
  const text = $("#fullPlayerTitleText");
  const changed = text.textContent !== title;
  if (changed) {
    text.textContent = title;
    $("#fullPlayerTitleRepeat").textContent = title;
  }
  viewport.setAttribute("aria-label", title);
  viewport.title = title;
  if (changed && $("#nowPlayingDialog").open) syncFullPlayerTitleMarquee();
}

function installedVideoAnimationDuration(duration) {
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches
    ? 0
    : duration;
}

function setInstalledVideoSourceGeometry(sourceRect, targetRect) {
  const stage = $(".installed-video-stage");
  const sourceArtwork = $("#fullPlayerArtwork");
  const sourceStyle = getComputedStyle(sourceArtwork);
  const targetStyle = getComputedStyle(stage);
  const targetWidth = Math.max(targetRect.width, 1);
  const targetHeight = Math.max(targetRect.height, 1);
  const sourceWidth = Math.max(sourceRect.width, 1);
  const sourceHeight = Math.max(sourceRect.height, 1);
  const sourceScaleX = sourceWidth / targetWidth;
  const sourceScaleY = sourceHeight / targetHeight;
  const sourceRadius = Number.parseFloat(sourceStyle.borderTopLeftRadius) || 22;
  stage.style.setProperty("--video-source-left", `${sourceRect.left}px`);
  stage.style.setProperty("--video-source-top", `${sourceRect.top}px`);
  stage.style.setProperty("--video-source-width", `${sourceWidth}px`);
  stage.style.setProperty("--video-source-height", `${sourceHeight}px`);
  stage.style.setProperty("--video-source-translate-x", `${sourceRect.left - targetRect.left}px`);
  stage.style.setProperty("--video-source-translate-y", `${sourceRect.top - targetRect.top}px`);
  stage.style.setProperty("--video-source-scale-x", String(sourceScaleX));
  stage.style.setProperty("--video-source-scale-y", String(sourceScaleY));
  stage.style.setProperty("--video-source-radius-x", `${sourceRadius / sourceScaleX}px`);
  stage.style.setProperty("--video-source-radius-y", `${sourceRadius / sourceScaleY}px`);
  stage.style.setProperty("--video-source-radius", sourceStyle.borderRadius || "22px");
  stage.style.setProperty("--video-source-border-color", sourceStyle.borderColor || "#a678ff80");
  stage.style.setProperty("--video-source-shadow", sourceStyle.boxShadow || "none");

  const transitionArtwork = $("#installedVideoArtwork");
  transitionArtwork.style.background = sourceStyle.background;
  transitionArtwork.style.color = sourceStyle.color;
  transitionArtwork.style.fontSize = sourceStyle.fontSize;

  return {
    source: {
      transform: `translate3d(${sourceRect.left - targetRect.left}px, ${sourceRect.top - targetRect.top}px, 0) scale(${sourceScaleX}, ${sourceScaleY})`,
      borderRadius: `${sourceRadius / sourceScaleX}px / ${sourceRadius / sourceScaleY}px`,
    },
    target: {
      transform: "translate3d(0, 0, 0) scale(1, 1)",
      borderRadius: targetStyle.borderRadius,
    },
    targetRect: {
      top: targetRect.top,
      left: targetRect.left,
      width: targetWidth,
      height: targetHeight,
    },
  };
}

function installedVideoStageGeometry() {
  const style = getComputedStyle($(".installed-video-stage"));
  return {
    transform: style.transform === "none" ? "translate3d(0, 0, 0) scale(1, 1)" : style.transform,
    borderRadius: style.borderRadius,
  };
}

function applyInstalledVideoStageGeometry(geometry) {
  const style = $(".installed-video-stage").style;
  style.transform = geometry.transform;
  style.borderRadius = geometry.borderRadius;
}

function clearInstalledVideoStageGeometry() {
  const style = $(".installed-video-stage").style;
  style.removeProperty("transform");
  style.removeProperty("border-radius");
}

function cancelInstalledVideoGeometryAnimation() {
  if (!installedVideoGeometryAnimation) return;
  installedVideoGeometryAnimation.cancel();
  installedVideoGeometryAnimation = null;
  $(".installed-video-stage").classList.remove("video-geometry-animating");
}

function animateInstalledVideoStage(from, to, onFinish) {
  cancelInstalledVideoGeometryAnimation();
  const stage = $(".installed-video-stage");
  stage.classList.add("video-geometry-animating");
  applyInstalledVideoStageGeometry(from);
  const duration = installedVideoAnimationDuration(INSTALLED_VIDEO_TRANSITION_MS);
  if (duration <= 0) {
    applyInstalledVideoStageGeometry(to);
    if (to.transform === "translate3d(0, 0, 0) scale(1, 1)") clearInstalledVideoStageGeometry();
    stage.classList.remove("video-geometry-animating");
    onFinish();
    return;
  }

  const animation = stage.animate([from, to], {
    duration,
    easing: "cubic-bezier(.25, .1, .25, 1)",
    fill: "both",
  });
  installedVideoGeometryAnimation = animation;
  animation.onfinish = () => {
    if (installedVideoGeometryAnimation !== animation) return;
    installedVideoGeometryAnimation = null;
    applyInstalledVideoStageGeometry(to);
    animation.cancel();
    if (to.transform === "translate3d(0, 0, 0) scale(1, 1)") clearInstalledVideoStageGeometry();
    stage.classList.remove("video-geometry-animating");
    onFinish();
  };
}

function installedVideoTrack() {
  return installedVideoSession
    ? state.tracks.find((track) => track.id === installedVideoSession.trackID) || null
    : null;
}

function installedVideoBounds(track = installedVideoTrack()) {
  const storedDuration = Number(track?.duration) || 0;
  const duration = storedDuration || Number(installedVideoPlayer.duration) || 0;
  const range = track ? playbackRangeForTrack(state, track) : null;
  return {
    start: range?.startSeconds ?? 0,
    end: range?.endSeconds ?? duration,
    duration,
  };
}

function syncInstalledVideoVolume() {
  const value = normalizedVolume(state.volume);
  installedVideoPlayer.muted = true;
  installedVideoPlayer.volume = 0;
  const input = $("#installedVideoVolume");
  input.value = String(value);
  input.setAttribute("aria-valuetext", `${Math.round(value * 100)} percent`);
  paintRange(input);
}

function syncInstalledVideoProgress() {
  const { start, end, duration } = installedVideoBounds();
  const current = Math.max(start, Math.min(Number(audio.currentTime) || 0, end || duration));
  const span = Math.max(0, end - start);
  const seek = $("#installedVideoSeek");
  seek.value = span > 0 ? String(Math.round((current - start) / span * 1000)) : "0";
  seek.setAttribute("aria-valuetext", `${formatTime(current)} of ${formatTime(end || duration)}`);
  $("#installedVideoElapsed").textContent = formatTime(current);
  $("#installedVideoDuration").textContent = formatTime(end || duration);
  paintRange(seek);
}

function syncInstalledVideoTransport() {
  const playing = !audio.paused && !audio.ended;
  const toggleButton = $("#installedVideoToggle");
  toggleButton.innerHTML = playing ? playbackPauseIcon : playbackPlayIcon;
  toggleButton.setAttribute("aria-label", playing ? "Pause" : "Play");
  toggleButton.title = playing ? "Pause" : "Play";
  $("#installedVideoDialog").classList.toggle("video-paused", !playing);
  $("#installedVideoRepeat").classList.toggle("active", repeat);
  $("#installedVideoRepeat").setAttribute("aria-pressed", String(repeat));
  syncInstalledVideoVolume();
  syncInstalledVideoProgress();
}

function hideInstalledVideoControls() {
  if (installedVideoControlsTimer) {
    clearTimeout(installedVideoControlsTimer);
    installedVideoControlsTimer = null;
  }
  const dialog = $("#installedVideoDialog");
  const keyboardFocusedControl = dialog.querySelector(
    ".installed-video-return:focus-visible, .installed-video-window-actions :focus-visible, #installedVideoControls :focus-visible",
  );
  if (audio.paused || keyboardFocusedControl) return;
  dialog.classList.remove("video-controls-visible");
}

function showInstalledVideoControls({ keepVisible = false } = {}) {
  if (installedVideoControlsTimer) clearTimeout(installedVideoControlsTimer);
  installedVideoControlsTimer = null;
  $("#installedVideoDialog").classList.add("video-controls-visible");
  if (!keepVisible && !audio.paused) {
    installedVideoControlsTimer = setTimeout(hideInstalledVideoControls, INSTALLED_VIDEO_CONTROLS_TIMEOUT_MS);
  }
}

function synchronizeInstalledVideoWithAudio({ forceSeek = false } = {}) {
  const session = installedVideoSession;
  const track = installedVideoTrack();
  if (!session?.metadataReady || session.closing || !track) return;
  if (session.trackID !== currentID) return;
  const audioTime = clippedPlaybackPosition(audio.currentTime, track);
  if (forceSeek
      || Math.abs((Number(installedVideoPlayer.currentTime) || 0) - audioTime)
        > INSTALLED_VIDEO_SYNC_TOLERANCE_SECONDS) {
    installedVideoPlayer.currentTime = audioTime;
  }
  installedVideoPlayer.muted = true;
  installedVideoPlayer.volume = 0;
  installedVideoPlayer.playbackRate = Number(audio.playbackRate) || 1;
  if (audio.paused || audio.ended) {
    installedVideoPlayer.pause();
  } else if (installedVideoPlayer.paused || installedVideoPlayer.ended) {
    void installedVideoPlayer.play().catch((error) => {
      showInstalledVideoControls({ keepVisible: true });
      showNotice(error?.message ? `Could not play this video: ${error.message}` : "Resonance could not play this video.");
    });
  }
  syncInstalledVideoTransport();
}

function updateInstalledVideoTime() {
  const session = installedVideoSession;
  const track = installedVideoTrack();
  if (!session || !track || session.closing) return;
  synchronizeInstalledVideoWithAudio();
}

function installedVideoPlaybackStarted() {
  syncInstalledVideoTransport();
  showInstalledVideoControls();
  updateChrome();
}

function installedVideoPlaybackPlaying() {
  const session = installedVideoSession;
  if (!session || session.closing) return;
  installedVideoPlayer.muted = true;
  installedVideoPlayer.volume = 0;
  syncInstalledVideoTransport();
  updateChrome();
}

function installedVideoPlaybackPaused() {
  syncInstalledVideoTransport();
  if (!installedVideoSession?.closing && audio.paused) showInstalledVideoControls({ keepVisible: true });
  updateChrome();
}

function configureInstalledVideoSource(track, startTime) {
  const dialog = $("#installedVideoDialog");
  if (!installedVideoSession || !isInstalledVideoTrack(track)) return;
  installedVideoSession.trackID = track.id;
  installedVideoSession.metadataReady = false;
  $("#installedVideoArtwork").innerHTML = track.artwork
    ? squareArtworkImageMarkup(track.artwork)
    : '<span aria-hidden="true">♪</span>';
  $("#installedVideoTitle").textContent = track.title || "Untitled";
  $("#installedVideoArtist").textContent = track.artist || "Unknown Artist";
  installedVideoPlayer.src = track.fileUrl;
  installedVideoPlayer.playbackRate = Number(state.playbackRate) || 1;
  installedVideoPlayer.muted = true;
  installedVideoPlayer.volume = 0;
  syncInstalledVideoVolume();
  installedVideoPlayer.onloadedmetadata = () => {
    if (installedVideoSession?.trackID !== track.id) return;
    const { start, end, duration } = installedVideoBounds(track);
    const requested = Number.isFinite(Number(startTime)) ? Number(startTime) : start;
    installedVideoPlayer.currentTime = Math.max(start, Math.min(requested, Math.max((end || duration) - 0.05, start)));
    installedVideoSession.metadataReady = true;
    syncInstalledVideoTransport();
    if (dialog.classList.contains("video-revealed")) synchronizeInstalledVideoWithAudio({ forceSeek: true });
  };
  installedVideoPlayer.onerror = () => {
    showInstalledVideoControls({ keepVisible: true });
    showNotice("Resonance could not play this installed video.");
  };
  installedVideoPlayer.ontimeupdate = updateInstalledVideoTime;
  installedVideoPlayer.onplay = installedVideoPlaybackStarted;
  installedVideoPlayer.onplaying = installedVideoPlaybackPlaying;
  installedVideoPlayer.onpause = installedVideoPlaybackPaused;
  installedVideoPlayer.onseeked = () => synchronizeInstalledVideoWithAudio();
  installedVideoPlayer.onended = () => synchronizeInstalledVideoWithAudio({ forceSeek: true });
  installedVideoPlayer.load();
}

function openInstalledVideo(track = currentTrack()) {
  if (!isInstalledVideoTrack(track)) return;
  const dialog = $("#installedVideoDialog");
  if (dialog.open) return;

  const startTime = track.id === currentID
    ? Math.max(0, Number(audio.currentTime) || Number(state.position) || 0)
    : 0;
  const sourceRect = $("#fullPlayerArtwork").getBoundingClientRect();
  if (installedVideoTransitionTimer) clearTimeout(installedVideoTransitionTimer);
  cancelInstalledVideoGeometryAnimation();
  clearInstalledVideoStageGeometry();
  if (installedVideoChromeTimer) clearTimeout(installedVideoChromeTimer);
  if (installedVideoArtworkTimer) clearTimeout(installedVideoArtworkTimer);
  if (installedVideoControlsTimer) clearTimeout(installedVideoControlsTimer);
  installedVideoTransitionTimer = null;
  installedVideoChromeTimer = null;
  installedVideoArtworkTimer = null;
  installedVideoControlsTimer = null;
  dialog.classList.remove(
    "video-expanded",
    "video-revealed",
    "video-closing",
    "video-artwork-restored",
    "video-paused",
    "video-controls-visible",
    "video-mini",
  );
  dialog.showModal();
  const targetRect = $(".installed-video-stage").getBoundingClientRect();
  const geometry = setInstalledVideoSourceGeometry(sourceRect, targetRect);
  installedVideoSession = {
    trackID: track.id,
    metadataReady: false,
    closing: false,
    mini: false,
    geometry,
  };
  configureInstalledVideoSource(track, startTime);
  applyInstalledVideoStageGeometry(geometry.source);
  dialog.classList.add("video-active", "video-from-art");
  $("#nowPlayingDialog").classList.add("video-active");
  void $(".installed-video-stage").offsetWidth;
  installedVideoTransitionTimer = setTimeout(() => {
    installedVideoTransitionTimer = null;
    if (!installedVideoSession || installedVideoSession.closing) return;
    dialog.classList.remove("video-from-art");
    dialog.classList.add("video-expanded", "video-revealed");
    synchronizeInstalledVideoWithAudio({ forceSeek: true });
    const session = installedVideoSession;
    animateInstalledVideoStage(geometry.source, geometry.target, () => {
      if (installedVideoSession !== session || session.closing) return;
      showInstalledVideoControls();
      $("#closeInstalledVideo").focus();
    });
  }, installedVideoAnimationDuration(INSTALLED_VIDEO_LEAD_IN_MS));
}

function playInstalledVideoTrack(track, { recordHistory = true } = {}) {
  if (!isInstalledVideoTrack(track) || !installedVideoSession) return;
  play(track, null, { recordHistory });
  configureInstalledVideoSource(track, playbackRangeForTrack(state, track)?.startSeconds ?? 0);
  showInstalledVideoControls();
}

function selectInstalledVideoTarget(track, { recordHistory = true } = {}) {
  if (!track) return;
  if (isInstalledVideoTrack(track)) {
    playInstalledVideoTrack(track, { recordHistory });
    return;
  }
  play(track, null, { recordHistory });
  closeInstalledVideo();
}

function advanceInstalledVideo(direction = 1) {
  const tracks = activePlaybackTracks();
  const index = nextIndex(tracks, currentID, direction);
  if (index < 0) return false;
  selectInstalledVideoTarget(tracks[index], { recordHistory: direction > 0 });
  return true;
}

function previousInstalledVideo() {
  const { start } = installedVideoBounds();
  if (audio.currentTime > start + 3) {
    audio.currentTime = start;
    installedVideoPlayer.currentTime = start;
    state.position = start;
    syncInstalledVideoProgress();
    return;
  }
  const previousID = history.pop();
  const previousTrack = previousID && state.tracks.find((track) =>
    track.id === previousID && trackBelongsToActiveProfile(state, track));
  if (previousTrack) selectInstalledVideoTarget(previousTrack, { recordHistory: false });
  else advanceInstalledVideo(-1);
}

function toggleInstalledVideoPlayback() {
  toggle();
  synchronizeInstalledVideoWithAudio({ forceSeek: true });
}

function minimizeInstalledVideo() {
  const dialog = $("#installedVideoDialog");
  const session = installedVideoSession;
  if (!dialog.open || !session || session.closing || session.mini) return;
  if (installedVideoTransitionTimer) clearTimeout(installedVideoTransitionTimer);
  if (installedVideoChromeTimer) clearTimeout(installedVideoChromeTimer);
  if (installedVideoArtworkTimer) clearTimeout(installedVideoArtworkTimer);
  if (installedVideoControlsTimer) clearTimeout(installedVideoControlsTimer);
  installedVideoTransitionTimer = null;
  installedVideoChromeTimer = null;
  installedVideoArtworkTimer = null;
  installedVideoControlsTimer = null;
  cancelInstalledVideoGeometryAnimation();
  session.mini = true;
  session.closing = false;
  dialog.classList.remove(
    "video-active",
    "video-from-art",
    "video-expanded",
    "video-closing",
    "video-artwork-restored",
  );
  dialog.classList.add("video-mini", "video-revealed", "video-controls-visible");
  $("#nowPlayingDialog").classList.remove("video-active");
  dialog.close();
  finishNowPlayingClose();
  dialog.show();
  clearInstalledVideoStageGeometry();
  synchronizeInstalledVideoWithAudio({ forceSeek: true });
  showInstalledVideoControls();
  requestAnimationFrame(() => $("#restoreInstalledVideo").focus());
}

function restoreInstalledVideo() {
  const dialog = $("#installedVideoDialog");
  const session = installedVideoSession;
  if (!dialog.open || !session?.mini || session.closing) return;
  dialog.close();
  session.mini = false;
  openNowPlaying();
  dialog.classList.remove("video-mini", "video-closing", "video-artwork-restored");
  dialog.classList.add("video-active", "video-expanded", "video-revealed", "video-controls-visible");
  $("#nowPlayingDialog").classList.add("video-active");
  clearInstalledVideoStageGeometry();
  dialog.showModal();
  synchronizeInstalledVideoWithAudio({ forceSeek: true });
  showInstalledVideoControls();
  requestAnimationFrame(() => $("#minimizeInstalledVideo").focus());
}

function finishInstalledVideoClose({ session }) {
  const dialog = $("#installedVideoDialog");
  cancelInstalledVideoGeometryAnimation();
  installedVideoPlayer.onloadedmetadata = null;
  installedVideoPlayer.onerror = null;
  installedVideoPlayer.ontimeupdate = null;
  installedVideoPlayer.onplay = null;
  installedVideoPlayer.onplaying = null;
  installedVideoPlayer.onpause = null;
  installedVideoPlayer.onseeked = null;
  installedVideoPlayer.onended = null;
  installedVideoPlayer.removeAttribute("src");
  installedVideoPlayer.load();
  installedVideoPlayer.muted = true;
  installedVideoSession = null;
  installedVideoTransitionTimer = null;
  if (installedVideoChromeTimer) clearTimeout(installedVideoChromeTimer);
  installedVideoChromeTimer = null;
  if (installedVideoArtworkTimer) clearTimeout(installedVideoArtworkTimer);
  installedVideoArtworkTimer = null;
  if (installedVideoControlsTimer) clearTimeout(installedVideoControlsTimer);
  installedVideoControlsTimer = null;
  if (dialog.open) dialog.close();
  dialog.classList.remove(
    "video-active",
    "video-from-art",
    "video-expanded",
    "video-revealed",
    "video-closing",
    "video-artwork-restored",
    "video-controls-visible",
    "video-paused",
    "video-mini",
  );
  $("#nowPlayingDialog").classList.remove("video-active");
  $("#installedVideoArtwork").replaceChildren();
  $("#installedVideoArtwork").removeAttribute("style");
  clearInstalledVideoStageGeometry();

  updateChrome();
}

function closeInstalledVideo() {
  const dialog = $("#installedVideoDialog");
  const session = installedVideoSession;
  if (!dialog.open || !session || session.closing) return;
  if (session.mini) {
    session.closing = true;
    installedVideoPlayer.pause();
    finishInstalledVideoClose({ session });
    return;
  }
  session.closing = true;

  installedVideoPlayer.pause();
  if (installedVideoTransitionTimer) {
    clearTimeout(installedVideoTransitionTimer);
    installedVideoTransitionTimer = null;
  }
  if (installedVideoChromeTimer) {
    clearTimeout(installedVideoChromeTimer);
    installedVideoChromeTimer = null;
  }
  if (installedVideoControlsTimer) {
    clearTimeout(installedVideoControlsTimer);
    installedVideoControlsTimer = null;
  }
  if (installedVideoArtworkTimer) {
    clearTimeout(installedVideoArtworkTimer);
    installedVideoArtworkTimer = null;
  }
  const sourceRect = $("#fullPlayerArtwork").getBoundingClientRect();
  const currentGeometry = installedVideoStageGeometry();
  const geometry = setInstalledVideoSourceGeometry(
    sourceRect,
    {
      top: $(".installed-video-stage").offsetTop,
      left: $(".installed-video-stage").offsetLeft,
      width: $(".installed-video-stage").offsetWidth,
      height: $(".installed-video-stage").offsetHeight,
    },
  );
  session.geometry = geometry;
  dialog.classList.remove(
    "video-active",
    "video-from-art",
    "video-expanded",
    "video-controls-visible",
    "video-paused",
  );
  dialog.classList.add("video-revealed", "video-closing");
  const geometryDuration = installedVideoAnimationDuration(INSTALLED_VIDEO_TRANSITION_MS);
  installedVideoArtworkTimer = setTimeout(() => {
    installedVideoArtworkTimer = null;
    if (installedVideoSession !== session || !session.closing) return;
    dialog.classList.add("video-artwork-restored");
  }, Math.max(geometryDuration - installedVideoAnimationDuration(INSTALLED_VIDEO_EXIT_ARTWORK_LEAD_MS), 0));
  installedVideoChromeTimer = setTimeout(() => {
    installedVideoChromeTimer = null;
    if (installedVideoSession !== session || !session.closing) return;
    $("#nowPlayingDialog").classList.remove("video-active");
    syncFullPlayerTitleMarquee();
  }, Math.max(geometryDuration - installedVideoAnimationDuration(INSTALLED_VIDEO_CHROME_RESTORE_LEAD_MS), 0));
  animateInstalledVideoStage(currentGeometry, geometry.source, () => {
    if (installedVideoSession !== session || !session.closing) return;
    finishInstalledVideoClose({ session });
  });
}

function renderFullPlayer() {
  const dialog = $("#nowPlayingDialog");
  const track = currentTrack();
  if (!track) {
    $("#openNowPlaying").disabled = true;
    if (dialog.open) dialog.close();
    return;
  }
  const liked = state.favorites.includes(track.id);
  $("#openNowPlaying").disabled = false;
  $("#openNowPlaying").setAttribute("aria-label", `Open Now Playing for ${track.title || "current song"}`);
  setFullPlayerTitle(track.title || "Untitled");
  $("#fullPlayerArtist").textContent = track.artist || "Unknown Artist";
  const releaseYear = Number(track.year || track.releaseYear) || null;
  $("#fullPlayerAlbum").textContent = [displayAlbum(track), releaseYear].filter(Boolean).join(" • ");
  const artworkNode = $("#fullPlayerArtwork");
  const artworkContentNode = $("#fullPlayerArtworkContent");
  artworkContentNode.innerHTML = track.artwork ? squareArtworkImageMarkup(track.artwork) : '<span aria-hidden="true">♪</span>';
  artworkContentNode.setAttribute("aria-label", `Artwork for ${track.title || "current song"}`);
  const videoLaunch = $("#fullPlayerVideoLaunch");
  const videoAvailable = isInstalledVideoTrack(track);
  artworkNode.classList.toggle("video-available", videoAvailable);
  videoLaunch.hidden = !videoAvailable;
  videoLaunch.disabled = !videoAvailable;
  videoLaunch.setAttribute("aria-label", `Watch video for ${track.title || "current song"}`);
  const backdropNode = $("#fullPlayerBackdrop");
  backdropNode.innerHTML = track.artwork ? squareArtworkImageMarkup(track.artwork) : "";
  const favorite = $("#fullPlayerFavorite");
  favorite.classList.toggle("active", liked);
  favorite.disabled = Boolean(track.transientStream);
  favorite.setAttribute("aria-pressed", String(liked));
  favorite.setAttribute("aria-label", liked ? "Remove current song from Liked Songs" : "Add current song to Liked Songs");
  favorite.title = liked ? "Remove from Liked Songs" : "Add to Liked Songs";
  $("#fullPlayerMore").disabled = Boolean(track.transientStream);
  $("#fullPlayerShuffle").classList.toggle("active", shuffle);
  $("#fullPlayerShuffle").setAttribute("aria-pressed", String(shuffle));
  $("#fullPlayerRepeat").classList.toggle("active", repeat);
  $("#fullPlayerRepeat").setAttribute("aria-pressed", String(repeat));
  setCustomSelectValue($("#fullPlayerSpeed"), audio.playbackRate || state.playbackRate || 1);
  $("#fullPlayerVolume").value = String(state.volume);
  $("#fullPlayerVolume").setAttribute("aria-valuetext", `${Math.round(state.volume * 100)} percent`);
  paintRange($("#fullPlayerVolume"));
  updateFullPlayerProgress();
  renderFullPlayerQueue();
}

function setFullPlayerQueueVisible(visible) {
  $("#fullPlayerQueuePanel").hidden = !visible;
  $("#fullPlayerQueueToggle").setAttribute("aria-expanded", String(visible));
  if (visible) {
    renderFullPlayerQueue();
    requestAnimationFrame(() => $("#closeFullPlayerQueue").focus());
  } else {
    $("#fullPlayerQueueToggle").focus();
  }
}

function openNowPlaying() {
  if (!currentTrack()) return;
  closeTrackContextMenu();
  renderFullPlayer();
  const dialog = $("#nowPlayingDialog");
  const menu = $("#trackContextMenu");
  if (nowPlayingCloseTimer) {
    clearTimeout(nowPlayingCloseTimer);
    nowPlayingCloseTimer = null;
  }
  dialog.classList.remove("closing");
  $(".full-player-shell").append(menu);
  if (!dialog.open) dialog.showModal();
  requestAnimationFrame(() => {
    syncFullPlayerTitleMarquee();
    $("#closeNowPlaying").focus();
  });
}

function finishNowPlayingClose() {
  if (nowPlayingCloseTimer) {
    clearTimeout(nowPlayingCloseTimer);
    nowPlayingCloseTimer = null;
  }
  const dialog = $("#nowPlayingDialog");
  if (dialog.open) dialog.close();
  dialog.classList.remove("closing");
}

function closeNowPlaying() {
  closeTrackContextMenu();
  setFullPlayerQueueVisible(false);
  const dialog = $("#nowPlayingDialog");
  if (!dialog.open || dialog.classList.contains("closing")) return;
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    finishNowPlayingClose();
    return;
  }
  dialog.classList.add("closing");
  nowPlayingCloseTimer = setTimeout(finishNowPlayingClose, FULL_PLAYER_TRANSITION_MS + 80);
}

function updateChrome() {
  const track = currentTrack();
  const playing = track && playbackIsActive();
  const liked = Boolean(track && state.favorites.includes(track.id));
  const transientStream = Boolean(track?.transientStream);
  $("#bottomTitle").textContent = track?.title || "Nothing playing";
  $("#bottomMeta").textContent = track ? `${track.artist} / ${playing ? "Now playing" : "Paused"}` : "Local library";
  $(".mini-art").innerHTML = track?.artwork ? squareArtworkImageMarkup(track.artwork) : "♪";
  document.querySelectorAll("[data-action=toggle]").forEach((button) => {
    button.innerHTML = playing ? playbackPauseIcon : playbackPlayIcon;
    button.setAttribute("aria-label", playing ? "Pause" : "Play");
    button.title = playing ? "Pause" : "Play";
  });
  const collectionButton = $("#playCollection");
  const collectionPlaying = playing && isCurrentCollectionPlayback();
  if (collectionButton) collectionButton.innerHTML = `<span class="button-icon">${collectionPlaying ? playbackPauseIcon : playbackPlayIcon}</span><span>${collectionPlaying ? "Pause" : "Play"}</span>`;
  $("#favoriteCurrent").textContent = liked ? "♥" : "♡";
  $("#favoriteCurrent").disabled = !track || Boolean(track.transientStream);
  $("#favoriteCurrent").setAttribute("aria-pressed", String(liked));
  $("#favoriteCurrent").setAttribute("aria-label", liked ? "Remove current song from Liked Songs" : "Add current song to Liked Songs");
  $("#favoriteCurrent").title = liked ? "Remove from Liked Songs" : "Add to Liked Songs";
  $("#shuffle").classList.toggle("active", shuffle);
  $("#repeat").classList.toggle("active", repeat);
  $("#shuffle").setAttribute("aria-pressed", String(shuffle));
  $("#repeat").setAttribute("aria-pressed", String(repeat));
  $("#heroShuffle")?.setAttribute("aria-pressed", String(shuffle));
  document.querySelectorAll("[data-action=next], [data-action=previous]").forEach((button) => {
    button.disabled = transientStream;
    button.title = transientStream ? "Unavailable for one-song server playback" : button.dataset.action === "next" ? "Next" : "Previous";
    button.setAttribute("aria-label", button.title);
  });
  for (const button of [$("#shuffle"), $("#fullPlayerShuffle"), $("#heroShuffle")].filter(Boolean)) {
    button.disabled = transientStream;
    button.title = transientStream ? "Unavailable for one-song server playback" : "Shuffle";
    button.setAttribute("aria-label", button.title);
  }
  if ($("#installedVideoDialog").open) syncInstalledVideoTransport();
  renderFullPlayer();
  bindSquareArtworkImages();
  scheduleDiscordPresenceUpdate();
}

function syncRepeatControls() {
  for (const button of [$("#repeat"), $("#fullPlayerRepeat"), $("#installedVideoRepeat")].filter(Boolean)) {
    button.classList.toggle("active", repeat);
    button.setAttribute("aria-pressed", String(repeat));
  }
}

function setRepeatEnabled(value) {
  repeat = Boolean(value);
  state.repeat = repeat;
  persistInBackground({ refreshSidebar: false });
  syncRepeatControls();
}

function setActiveNav() { document.querySelectorAll(".nav").forEach((button) => button.classList.toggle("active", button.dataset.section === section)); }

function applyNavigation(location) {
  closeProfileMenu();
  if (location.section === "server" && section !== "server") serverAutoAttempted = false;
  if (location.section === "library" && location.playlistID !== selectedPlaylistID) libraryQuery = "";
  section = location.section;
  selectedPlaylistID = location.playlistID;
  updateTopSearch();
  setActiveNav(); render();
}

function navigate(nextSection, playlistID = null) {
  const next = { section: nextSection, playlistID };
  const current = navigationHistory[navigationIndex];
  if (current.section === next.section && current.playlistID === next.playlistID) return;
  navigationHistory = navigationHistory.slice(0, navigationIndex + 1);
  navigationHistory.push(next); navigationIndex = navigationHistory.length - 1;
  applyNavigation(next);
}

initializeCustomSelects();
document.querySelectorAll(".nav").forEach((button) => button.onclick = () => navigate(button.dataset.section));
$("#navBack").onclick = () => { if (navigationIndex > 0) { navigationIndex -= 1; applyNavigation(navigationHistory[navigationIndex]); } };
$("#navForward").onclick = () => { if (navigationIndex + 1 < navigationHistory.length) { navigationIndex += 1; applyNavigation(navigationHistory[navigationIndex]); } };
document.querySelectorAll("[data-action=toggle]").forEach((button) => button.onclick = toggle);
document.querySelectorAll("[data-action=next]").forEach((button) => button.onclick = () => move(1));
document.querySelectorAll("[data-action=previous]").forEach((button) => button.onclick = previous);
$("#openNowPlaying").onclick = () => {
  if (installedVideoSession?.mini) restoreInstalledVideo();
  else openNowPlaying();
};
$("#closeNowPlaying").onclick = closeNowPlaying;
$("#fullPlayerVideoLaunch").onclick = () => {
  const track = currentTrack();
  if (isInstalledVideoTrack(track)) openInstalledVideo(track);
};
$("#closeInstalledVideo").onclick = () => closeInstalledVideo();
$("#minimizeInstalledVideo").onclick = minimizeInstalledVideo;
$("#restoreInstalledVideo").onclick = restoreInstalledVideo;
$("#dismissMiniVideo").onclick = () => closeInstalledVideo();
$("#installedVideoToggle").onclick = toggleInstalledVideoPlayback;
$("#installedVideoPrevious").onclick = previousInstalledVideo;
$("#installedVideoNext").onclick = () => advanceInstalledVideo(1);
$("#installedVideoRepeat").onclick = () => {
  setRepeatEnabled(!repeat);
  showInstalledVideoControls();
};
$("#installedVideoSeek").oninput = (event) => {
  const { start, end } = installedVideoBounds();
  if (end > start) {
    const position = start + (end - start) * Number(event.target.value) / 1000;
    audio.currentTime = position;
    installedVideoPlayer.currentTime = position;
    state.position = position;
  }
  syncInstalledVideoProgress();
  showInstalledVideoControls();
};
const installedVideoStage = $(".installed-video-stage");
installedVideoStage.onpointermove = () => showInstalledVideoControls();
installedVideoStage.onpointerenter = () => showInstalledVideoControls();
installedVideoStage.onpointerleave = () => showInstalledVideoControls();
const installedVideoControls = $("#installedVideoControls");
installedVideoControls.onpointerenter = () => showInstalledVideoControls();
installedVideoControls.onpointerleave = () => showInstalledVideoControls();
installedVideoControls.onfocusin = (event) => {
  showInstalledVideoControls({ keepVisible: event.target.matches(":focus-visible") });
};
installedVideoControls.onfocusout = () => showInstalledVideoControls();
$("#installedVideoDialog").addEventListener("focusin", (event) => {
  if (!event.target.closest(".installed-video-return, .installed-video-window-actions")) return;
  showInstalledVideoControls({ keepVisible: event.target.matches(":focus-visible") });
});
$("#installedVideoDialog").addEventListener("focusout", (event) => {
  if (event.target.closest(".installed-video-return, .installed-video-window-actions")) {
    showInstalledVideoControls();
  }
});
$("#installedVideoDialog").addEventListener("cancel", (event) => {
  event.preventDefault();
  closeInstalledVideo();
});
$("#nowPlayingDialog").addEventListener("cancel", (event) => {
  event.preventDefault();
  closeNowPlaying();
});
$("#nowPlayingDialog").addEventListener("animationend", (event) => {
  if (event.target === $("#nowPlayingDialog") && event.animationName === "full-player-slide-out") {
    finishNowPlayingClose();
  }
});
$("#nowPlayingDialog").addEventListener("close", () => {
  if (nowPlayingCloseTimer) {
    clearTimeout(nowPlayingCloseTimer);
    nowPlayingCloseTimer = null;
  }
  $("#nowPlayingDialog").classList.remove("closing");
  const menu = $("#trackContextMenu");
  document.body.insertBefore(menu, $("#localImportPreview"));
  $("#fullPlayerQueuePanel").hidden = true;
  $("#fullPlayerQueueToggle").setAttribute("aria-expanded", "false");
  $("#openNowPlaying").focus();
});
$("#settingsDialog").addEventListener("close", () => {
  settingsRecordingAction = null;
  $("#profileButton")?.focus();
});
$("#fullPlayerFavorite").onclick = () => currentID && toggleFavorite(currentID);
$("#fullPlayerMore").onclick = (event) => currentID && openTrackContextMenu(event, currentID, {
  playbackTracks: activePlaybackTracks(),
  playlistID: activePlaybackPlaylistID,
  source: "full-player",
  alignToEnd: true,
});
$("#fullPlayerQueueToggle").onclick = () => setFullPlayerQueueVisible($("#fullPlayerQueuePanel").hidden);
$("#closeFullPlayerQueue").onclick = () => setFullPlayerQueueVisible(false);
const fullPlayerQueueTabs = [...document.querySelectorAll("[data-full-player-queue-tab]")];
fullPlayerQueueTabs.forEach((button) => {
  button.onclick = () => {
    fullPlayerQueueTab = button.dataset.fullPlayerQueueTab;
    renderFullPlayerQueue();
  };
  button.onkeydown = (event) => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const currentIndex = fullPlayerQueueTabs.indexOf(button);
    const nextIndex = event.key === "Home" ? 0
      : event.key === "End" ? fullPlayerQueueTabs.length - 1
        : (currentIndex + (event.key === "ArrowRight" ? 1 : -1) + fullPlayerQueueTabs.length) % fullPlayerQueueTabs.length;
    const next = fullPlayerQueueTabs[nextIndex];
    fullPlayerQueueTab = next.dataset.fullPlayerQueueTab;
    renderFullPlayerQueue();
    next.focus();
  };
});
$("#fullPlayerShuffle").onclick = () => {
  setShuffleEnabled(!shuffle);
};
$("#fullPlayerRepeat").onclick = () => {
  setRepeatEnabled(!repeat);
};
$("#newPlaylist").onclick = () => newPlaylist();
$("#profileButton").onclick = toggleProfileMenu;
$("#profileMenuManage").onclick = () => openSettings("server");
$("#profileMenuEmail").onclick = (event) => {
  if (!accountSession?.email) return;
  event.preventDefault();
  event.stopPropagation();
  isAccountEmailRevealed = !isAccountEmailRevealed;
  updateProfileControlView({ refreshPicture: false });
};
$("#profileHistory").onclick = openListeningHistory;
$("#profileClipEditor").onclick = openClipEditor;
$("#profileSettings").onclick = () => {
  openSettings();
};
$("#dismissServerTransfer").onclick = cancelServerTransfer;
$("#dismissAppNotice").onclick = dismissNotice;
$("#cancelPlaylist").onclick = () => { pendingPlaylistTrackID = null; $("#playlistDialog").close(); };
$("#playlistName").oninput = () => { $("#createPlaylist").disabled = !$("#playlistName").value.trim(); };
$("#closeAddSongs").onclick = () => $("#addSongsDialog").close();
$("#previewClipRange").onclick = toggleClipRangePreview;
$("#saveClipRange").onclick = saveClipRange;
$("#closeClipEditor").onclick = () => { void stopClipRangePreview().then(() => $("#clipEditorDialog").close()); };
$("#clearClipRange").onclick = clearClipRange;
$("#clipEditorSettingsButton").onclick = () => toggleClipEditorPopover("settings");
$("#clipEditorHelpButton").onclick = () => toggleClipEditorPopover("help");
$("#closeClipEditorSettings").onclick = () => toggleClipEditorPopover("settings");
$("#closeClipEditorHelp").onclick = () => toggleClipEditorPopover("help");
$("#clipEditorSkipStart").onclick = () => { void seekClipEditorPreview(clipEditorStartSeconds); };
$("#clipEditorSkipEnd").onclick = () => { void seekClipEditorPreview(clipEditorEndSeconds - .01); };
$("#clipEditorExpand").onclick = () => {
  const expanded = $("#clipEditorDialog").classList.toggle("preview-expanded");
  $("#clipEditorExpand").setAttribute("aria-pressed", String(expanded));
  $("#clipEditorExpand").setAttribute("aria-label", expanded ? "Show clip timeline" : "Expand preview");
};
$("#clipEditorTrack").onchange = async () => { await stopClipRangePreview(); renderClipEditorTrack({ resetRange: true }); };
bindClipEditorHandle("start");
bindClipEditorHandle("end");
["start", "end"].forEach((boundary) => {
  const input = $(`#clipEditor${boundary === "start" ? "Start" : "End"}Input`);
  input.onfocus = () => input.select();
  input.onchange = () => commitClipEditorTime(boundary);
  input.onkeydown = (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      commitClipEditorTime(boundary);
      input.select();
    } else if (event.key === "Escape") {
      input.value = formatTime(boundary === "start" ? clipEditorStartSeconds : clipEditorEndSeconds);
      input.blur();
    }
  };
});
$("#clipEditorDialog").onclick = (event) => {
  if (event.target === $("#clipEditorDialog")) {
    void stopClipRangePreview().then(() => $("#clipEditorDialog").close());
  }
};
$("#clipEditorDialog").oncancel = () => { void stopClipRangePreview(); };
const clipEditorVisualizerResizeObserver = new ResizeObserver(() => {
  if (clipEditorPreviewAudio.paused || clipEditorPreviewAudio.ended) {
    drawClipEditorStageVisualizer(clipEditorVisualizerStaticLevels);
  }
});
clipEditorVisualizerResizeObserver.observe(clipEditorVisualizerCanvas);
$("#clipEditorWaveform").onpointerdown = (event) => {
  if (event.target.closest(".clip-editor-handle")) return;
  const seconds = clipEditorSecondsAtPointer(event);
  void seekClipEditorPreview(Math.max(clipEditorStartSeconds, Math.min(seconds, clipEditorEndSeconds)));
};
clipEditorPreviewAudio.onplay = syncClipRangePreviewButton;
clipEditorPreviewAudio.onpause = () => {
  syncClipRangePreviewButton();
  syncClipRangePreviewTransport();
};
clipEditorPreviewAudio.onloadedmetadata = syncClipRangePreviewTransport;
clipEditorPreviewAudio.onended = () => {
  syncClipRangePreviewButton();
  syncClipRangePreviewTransport();
  void resumePlaybackAfterClipRangePreview();
};
clipEditorPreviewAudio.ontimeupdate = () => {
  syncClipRangePreviewTransport();
  if (clipEditorPreviewAudio.paused) return;
  if (!clipEditorPreviewEndSeconds || clipEditorPreviewAudio.currentTime + 0.02 < clipEditorPreviewEndSeconds) return;
  clipEditorPreviewAudio.currentTime = clipEditorPreviewEndSeconds;
  clipEditorPreviewAudio.pause();
  $("#clipEditorStatus").textContent = "Preview complete. Drag the playback bar to review any moment in the range.";
  void resumePlaybackAfterClipRangePreview();
};
$("#clipEditorPreviewSeek").oninput = async (event) => {
  const track = clipEditorTrack();
  if (!track?.fileUrl) return;
  try {
    await prepareClipRangePreviewMedia(track);
    clipEditorPreviewAudio.currentTime = Math.min(
      Math.max(Number(event.target.value) || clipEditorStartSeconds, clipEditorStartSeconds),
      clipEditorEndSeconds
    );
    syncClipRangePreviewTransport();
  } catch {
    $("#clipEditorStatus").textContent = "Resonance could not seek this preview.";
  }
};
$("#addSongsSearch").oninput = renderAddSongsDialog;
$("#confirmLocalImport").onclick = confirmLinkImport;
$("#cancelLocalImport").onclick = cancelLinkImport;
$("#closeLocalImport").onclick = closeLocalImport;
localImportPreviewAudio.onplay = syncLocalImportPreviewButtons;
localImportPreviewAudio.onpause = syncLocalImportPreviewButtons;
localImportPreviewAudio.onended = () => {
  localImportPreviewAudio.currentTime = 0;
  syncLocalImportPreviewButtons();
  void resumePlaybackAfterLocalImportPreview();
};
localImportPreviewAudio.ontimeupdate = () => {
  if (localImportPreviewIndex === null || localImportPreviewAudio.currentTime < localImportPreviewLimitSeconds) return;
  localImportPreviewAudio.pause();
  localImportPreviewAudio.currentTime = 0;
  syncLocalImportPreviewButtons();
  void resumePlaybackAfterLocalImportPreview();
};
$("#chooseLocalFiles").onclick = async () => {
  if (localImportRunning) return;
  await stopLocalImportPreview({ release: true, resumeMain: true });
  $("#localImportDialog").close();
  await importAudio();
};
$("#localImportSource").onkeydown = (event) => {
  if (event.key !== "Enter") return;
  event.preventDefault();
  clearLocalImportAutoResolve();
  void resolveLinkImport();
};
$("#searchLocalImport").onclick = () => {
  clearLocalImportAutoResolve();
  void resolveLinkImport();
};
$("#localImportSource").oninput = () => {
  localImportInteractionGeneration += 1;
  if (localImportRunning) {
    localImportResolutionRestartPending = true;
    void api.cancelLocalImport();
  }
  localImportResolvedSourceKey = null;
  if (localImportResolution || !$("#localImportError").hidden) {
    void stopLocalImportPreview({ release: true, resumeMain: true });
    localImportResolution = null;
    $("#localImportResolved").hidden = true;
    $("#localImportSyncRow").hidden = true;
    $("#confirmLocalImport").hidden = true;
    $("#localImportError").hidden = true;
    setLocalImportStage({ stage: "idle" });
  }
  normalizeLocalImportMediaKindForSource();
  const sourceProvider = localImportProviderForSource($("#localImportSource").value);
  if (sourceProvider) setLocalImportProviderFocus(sourceProvider);
  scheduleLocalImportResolution();
};
$("#localImportSync").onchange = () => {
  localImportInteractionGeneration += 1;
  updateLocalImportConfirmLabel();
};
document.querySelectorAll('input[name="localImportMediaKind"]').forEach((input) => {
  input.onchange = () => {
    localImportInteractionGeneration += 1;
    normalizeLocalImportMediaKindForSource();
    if (localImportResolution || !$("#localImportError").hidden) {
      void stopLocalImportPreview({ release: true, resumeMain: true });
      localImportResolution = null;
      $("#localImportResolved").hidden = true;
      $("#localImportSyncRow").hidden = true;
      $("#confirmLocalImport").hidden = true;
      $("#localImportError").hidden = true;
    }
    localImportResolvedSourceKey = null;
    setLocalImportStage({ stage: "idle" });
    updateLocalImportMediaKindUI();
    scheduleLocalImportResolution({ immediate: true });
  };
});
document.querySelectorAll("[data-local-import-provider]").forEach((button) => {
  button.onclick = () => setLocalImportProviderFocus(button.dataset.localImportProvider, { scroll: true });
});
$("#localImportDialog").onclick = (event) => {
  if (event.target === $("#localImportDialog") && !localImportRunning) $("#localImportDialog").close();
};
$("#localImportDialog").addEventListener("close", () => {
  void stopLocalImportPreview({ release: true, resumeMain: true });
  if (localImportKeepStateOnClose) {
    localImportKeepStateOnClose = false;
    return;
  }
  resetLocalImport();
});
$("#addSongsList").onclick = async (event) => {
  const button = event.target.closest("[data-add-song]");
  if (!button) return;
  const playlist = state.playlists.find((item) => item.id === addSongsPlaylistID);
  if (!playlist) return;
  button.disabled = true;
  if (playlist.isSystem) {
    toggleFavorite(button.dataset.addSong);
    renderAddSongsDialog();
    return;
  }
  const added = playlist.trackIDs.includes(button.dataset.addSong);
  playlist.trackIDs = added
    ? playlist.trackIDs.filter((id) => id !== button.dataset.addSong)
    : [...playlist.trackIDs, button.dataset.addSong];
  updatePlaylistRemoteSongIDs(state, playlist);
  markPlaylistDirty(playlist);
  if (activePlaybackPlaylistID === playlist.id) setPlaybackContext(tracksForPlaylist(state, playlist.id), playlist.id);
  await persist();
  schedulePlaylistSync();
  renderAddSongsDialog();
};
$("#addSongsDialog").addEventListener("close", () => {
  addSongsPlaylistID = null;
  if (section === "library" && selectedPlaylistID) renderLibrary();
});
$("#closeListeningHistory").onclick = () => $("#listeningHistoryDialog").close();
$("#listeningHistoryRange").onchange = () => {
  listeningHistoryWindowOffset = 0;
  ensureListeningHistorySelection();
  renderListeningHistory();
};
$("#historyPreviousWindow").onclick = () => shiftListeningHistoryWindow(1);
$("#historyNextWindow").onclick = () => shiftListeningHistoryWindow(-1);
$("#listeningHistoryMode").onclick = (event) => {
  const button = event.target.closest("[data-history-mode]");
  if (!button) return;
  listeningHistoryMode = button.dataset.historyMode;
  ensureListeningHistorySelection();
  renderListeningHistory();
};
$("#listeningHistoryDialog").onclick = (event) => {
  if (event.target === $("#listeningHistoryDialog")) $("#listeningHistoryDialog").close();
};
$("#listeningHistoryDialog").addEventListener("close", () => {
  selectedListeningHistoryDayKey = null;
  $("#listeningHistoryDialog").classList.remove("day-expanded");
  $("#listeningHistoryDayDetails").hidden = true;
});
function keybindFromKeyboardEvent(event) {
  if (["Control", "Alt", "Shift", "Meta"].includes(event.key)) return null;
  let key = event.code === "Space" ? "Space" : event.key;
  if (key === " ") key = "Space";
  if (key.length === 1) key = key.toUpperCase();
  return [
    event.ctrlKey ? "Ctrl" : null,
    event.altKey ? "Alt" : null,
    event.shiftKey ? "Shift" : null,
    event.metaKey ? "Meta" : null,
    key,
  ].filter(Boolean).join("+");
}

function hasBlockingDialog() {
  return [...document.querySelectorAll("dialog[open]")]
    .some((dialog) => !dialog.matches("#installedVideoDialog.video-mini"));
}

document.addEventListener("keydown", (event) => {
  if (settingsRecordingAction) {
    event.preventDefault();
    event.stopImmediatePropagation();
    if (event.key === "Escape") {
      settingsRecordingAction = null;
      renderSettings();
      return;
    }
    const keybind = keybindFromKeyboardEvent(event);
    if (!keybind) return;
    const duplicate = Object.entries(state.appPreferences.keybinds).find(([action, value]) => action !== settingsRecordingAction && value === keybind);
    if (duplicate) {
      showNotice(`${keybind} is already assigned to ${settingsKeybindActions[duplicate[0]].label}.`);
      return;
    }
    state.appPreferences.keybinds[settingsRecordingAction] = keybind;
    settingsRecordingAction = null;
    persistInBackground({ refreshSidebar: false });
    renderSettings();
    return;
  }
  if (event.repeat || event.isComposing) return;
  const clipEditorOpen = $("#clipEditorDialog")?.open;
  const isTextEntry = event.target instanceof Element
    && Boolean(event.target.closest("input:not([type=range]), textarea, select, [contenteditable=true], [role=menu], [role=listbox]"));
  if (clipEditorOpen && !isTextEntry) {
    const keybind = keybindFromKeyboardEvent(event);
    const action = keybind
      ? Object.entries(state.appPreferences?.keybinds || {}).find(([, value]) => value === keybind)?.[0]
      : null;
    if (action && handleClipEditorKeybind(action)) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
    return;
  }
  if (event.defaultPrevented || hasBlockingDialog()) return;
  if (event.target instanceof Element && event.target.closest("input, textarea, select, button, [contenteditable=true], [role=menu], [role=listbox]")) return;
  const keybind = keybindFromKeyboardEvent(event);
  if (!keybind) return;
  const action = Object.entries(state.appPreferences?.keybinds || {}).find(([, value]) => value === keybind)?.[0];
  if (!action) return;
  event.preventDefault();
  if (action === "togglePlayback") toggle();
  else if (action === "previousTrack") previous();
  else if (action === "nextTrack") move(1);
  else if (action === "volumeDown") setPlaybackVolume(state.volume - .05);
  else if (action === "volumeUp") setPlaybackVolume(state.volume + .05);
});
document.addEventListener("click", (event) => {
  if (!$("#profileControl")?.contains(event.target)) closeProfileMenu();
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && !$("#profileMenu")?.hidden) {
    event.preventDefault();
    closeProfileMenu({ restoreFocus: true });
  }
});
window.addEventListener("blur", () => {
  document.querySelectorAll(".recent-track-item.hovering").forEach((button) => button.classList.remove("hovering"));
});
$("#playlistForm").onsubmit = async (event) => {
  event.preventDefault();
  const name = $("#playlistName").value.trim();
  if (!name) return;
  const playlist = {
    id: crypto.randomUUID().toLocaleLowerCase(),
    name,
    trackIDs: pendingPlaylistTrackID ? [pendingPlaylistTrackID] : [],
    remoteSongIDs: [],
    isSystem: false,
  };
  updatePlaylistRemoteSongIDs(state, playlist);
  markPlaylistDirty(playlist);
  state.playlists.push(playlist);
  pendingPlaylistTrackID = null;
  $("#playlistDialog").close();
  await persist();
  schedulePlaylistSync();
  render();
};
document.addEventListener("click", (event) => {
  if (!event.target.closest("#trackContextMenu")) closeTrackContextMenu();
  if (!event.target.closest("#searchSort")) closeSearchSort();
  if (!event.target.closest("#playlistMore")) $("#playlistMore")?.removeAttribute("open");
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    closeTrackContextMenu();
    closeSearchSort();
    $("#playlistMore")?.removeAttribute("open");
    if (section === "server" && serverSelecting) {
      serverSelecting = false;
      selectedRemoteIDs.clear();
      renderServer();
    }
  }
});
window.addEventListener("blur", closeTrackContextMenu);
window.addEventListener("focus", () => syncPlaylistsNow({ automatic: true }));
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") syncPlaylistsNow({ automatic: true });
});
$("#search").oninput = () => {
  const query = $("#search").value;
  setCurrentSearchQuery(query);
  if (section === "library") renderLibrary();
  else if (section === "playlists") renderPlaylists();
  else if (section === "storage") renderStorage();
  else renderServer();
};
$("#searchSortButton").onclick = () => {
  const sort = $("#searchSort");
  if (sort.classList.contains("open")) closeSearchSort({ restoreFocus: true });
  else openSearchSort();
};
$("#searchSortButton").onkeydown = (event) => {
  if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) return;
  event.preventDefault();
  const direction = event.key === "Home" ? "first" : event.key === "End" ? "last" : event.key === "ArrowDown" ? 1 : -1;
  openSearchSort(direction);
};
$("#searchSortMenu").onclick = (event) => {
  const scopeOption = event.target.closest("[data-search-scope]");
  if (section === "server" && scopeOption) {
    serverScope = scopeOption.dataset.searchScope;
    renderServer();
    closeSearchSort();
    return;
  }
  const option = event.target.closest("[data-search-sort]");
  if (!option) return;
  if (section === "storage") {
    storageSort = option.dataset.searchSort;
    renderStorage();
  } else if (section === "server") {
    serverSort = option.dataset.searchSort;
    renderServer();
  }
  updateTopSearch();
  closeSearchSort();
};
$("#searchSortMenu").onkeydown = (event) => {
  if (event.key === "Escape") {
    event.preventDefault();
    closeSearchSort({ restoreFocus: true });
  } else if (["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) {
    event.preventDefault();
    const direction = event.key === "Home" ? "first" : event.key === "End" ? "last" : event.key === "ArrowDown" ? 1 : -1;
    focusSearchSortOption(direction);
  } else if (event.key === "Tab") {
    closeSearchSort();
  }
};
$("#favoriteCurrent").onclick = () => currentID && toggleFavorite(currentID);
const playerTrackContextTarget = $(".player-track");
playerTrackContextTarget.tabIndex = 0;
playerTrackContextTarget.setAttribute("aria-keyshortcuts", "Shift+F10");
playerTrackContextTarget.oncontextmenu = (event) => {
  if (currentID) openTrackContextMenu(event, currentID, { playbackTracks: activePlaybackTracks(), playlistID: activePlaybackPlaylistID });
};
playerTrackContextTarget.onkeydown = (event) => {
  if (event.target !== playerTrackContextTarget || !currentID) return;
  if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) {
    event.preventDefault();
    openTrackContextMenu(event, currentID, { playbackTracks: activePlaybackTracks(), playlistID: activePlaybackPlaylistID });
  }
};
$("#shuffle").onclick = () => setShuffleEnabled(!shuffle);
$("#repeat").onclick = () => setRepeatEnabled(!repeat);
function paintRange(input) {
  const minimum = Number(input.min) || 0;
  const maximum = Number(input.max) || 100;
  const progress = maximum > minimum ? ((Number(input.value) - minimum) / (maximum - minimum)) * 100 : 0;
  input.style.setProperty("--range-progress", `${Math.max(0, Math.min(100, progress))}%`);
}

function setPlaybackVolume(value, { shouldPersist = true } = {}) {
  state.volume = normalizedVolume(value);
  const gain = playbackGainForVolume(state.volume);
  audio.volume = gain;
  installedVideoPlayer.muted = true;
  installedVideoPlayer.volume = 0;
  const percent = Math.round(state.volume * 100);
  [$("#volume"), $("#fullPlayerVolume"), $("#installedVideoVolume")].forEach((input) => {
    input.value = String(state.volume);
    input.setAttribute("aria-valuetext", `${percent} percent`);
    paintRange(input);
  });
  if (shouldPersist) persistInBackground({ refreshSidebar: false });
}

$("#volume").oninput = (event) => setPlaybackVolume(event.target.value);
$("#fullPlayerVolume").oninput = (event) => setPlaybackVolume(event.target.value);
$("#installedVideoVolume").oninput = (event) => {
  setPlaybackVolume(event.target.value);
  showInstalledVideoControls();
};
$("#speed").onchange = (event) => {
  audio.playbackRate = Number(event.target.value);
  installedVideoPlayer.playbackRate = audio.playbackRate;
  state.playbackRate = audio.playbackRate;
  setCustomSelectValue($("#fullPlayerSpeed"), audio.playbackRate);
  persistInBackground();
};
$("#fullPlayerSpeed").onchange = (event) => {
  audio.playbackRate = Number(event.target.value);
  installedVideoPlayer.playbackRate = audio.playbackRate;
  state.playbackRate = audio.playbackRate;
  setCustomSelectValue($("#speed"), audio.playbackRate);
  persistInBackground();
};
$("#seek").oninput = (event) => {
  const duration = currentPlaybackDuration();
  if (duration) audio.currentTime = clippedPlaybackPosition(duration * Number(event.target.value) / 1000);
  event.target.value = duration ? String(Math.round(audio.currentTime / duration * 1000)) : "0";
  event.target.setAttribute("aria-valuetext", `${formatTime(audio.currentTime)} of ${formatTime(duration)}`);
  paintRange(event.target);
};
$("#fullPlayerSeek").oninput = (event) => {
  const duration = currentPlaybackDuration();
  if (duration) audio.currentTime = clippedPlaybackPosition(duration * Number(event.target.value) / 1000);
  event.target.value = duration ? String(Math.round(audio.currentTime / duration * 1000)) : "0";
  updateFullPlayerProgress();
  $("#seek").value = event.target.value;
  $("#seek").setAttribute("aria-valuetext", `${formatTime(audio.currentTime)} of ${formatTime(duration)}`);
  paintRange($("#seek"));
};
audio.ontimeupdate = () => {
  if (pendingRestorePosition !== null) return;
  if (finishClipPlaybackIfNeeded()) return;
  updatePlaybackProgressUI();
  state.position = audio.currentTime;
  updateListeningSession();
  schedulePlaybackProgressSave();
  synchronizeInstalledVideoWithAudio();
};
audio.onplay = () => {
  beginListeningSession();
  startPlaybackProgressAnimation();
  synchronizeInstalledVideoWithAudio({ forceSeek: true });
  updateChrome();
  renderQueue();
};
audio.onpause = () => {
  stopPlaybackProgressAnimation();
  updatePlaybackProgressUI();
  updateListeningSession();
  scheduleListeningHistorySync();
  synchronizeInstalledVideoWithAudio({ forceSeek: true });
  updateChrome();
  if (playbackProgressTimer) {
    clearTimeout(playbackProgressTimer);
    playbackProgressTimer = null;
  }
  persistInBackground({ refreshSidebar: false });
};
audio.onended = () => {
  stopPlaybackProgressAnimation();
  updatePlaybackProgressUI();
  updateListeningSession();
  scheduleListeningHistorySync();
  const range = activeClipRange();
  if (repeat) {
    finishListeningSessionForReplay();
    const start = range?.startSeconds ?? 0;
    audio.currentTime = start;
    state.position = start;
    if (installedVideoSession?.metadataReady) installedVideoPlayer.currentTime = start;
    void requestPlayback();
  } else if ($("#installedVideoDialog").open && installedVideoSession) {
    advanceInstalledVideo(1);
  } else if (!move(1) && currentTrack()?.transientStream) {
    releaseActiveServerStream({ stopPlayback: true });
  }
};
audio.onerror = () => {
  stopPlaybackProgressAnimation();
  const streamFailed = Boolean(currentTrack()?.transientStream);
  if (streamFailed) releaseActiveServerStream({ stopPlayback: true });
  updateChrome();
  showNotice(streamFailed
    ? "This song could not be streamed. Check the connection and signed server policy, then try again."
    : "This song could not be played. The file may be missing, inaccessible, or unsupported.");
};
audio.onloadedmetadata = async () => {
  const track = playbackTrackByID(audioSourceTrackID);
  if (!track) return;
  audioMetadataTrackID = track.id;
  if (track.id === currentID && pendingRestorePosition !== null) {
    if (Number.isFinite(audio.duration) && audio.duration > 0) {
      const duration = currentPlaybackDuration(track);
      audio.currentTime = clippedPlaybackPosition(Math.min(pendingRestorePosition, Math.max(0, duration - 0.25)));
      state.position = audio.currentTime;
    }
    pendingRestorePosition = null;
  }
  if (!track.transientStream && !isInstalledVideoTrack(track) && audio.duration && track.duration !== audio.duration) {
    track.duration = audio.duration;
    await persist();
    renderQueue();
  } else if (track.transientStream && audio.duration && track.duration !== audio.duration) {
    activeServerStream.track = Object.freeze({ ...track, duration: audio.duration });
    renderQueue();
  }
  if (track.id === currentID) updateFullPlayerProgress();
};

api.onDiscordPresenceStatus((status) => {
  discordPresenceStatus = status || discordPresenceStatus;
  const statusCopy = $("#settingsDiscordStatus");
  if (statusCopy) statusCopy.textContent = discordPresenceStatus.message || "Show Resonance playback on your signed-in Discord profile.";
});
discordPresenceStatus = await api.getDiscordPresenceStatus().catch(() => discordPresenceStatus);
const libraryLoad = await api.loadLibrary();
const loadedState = libraryLoad && Object.hasOwn(libraryLoad, "state") ? libraryLoad.state : libraryLoad;
state = normalizeState(loadedState);
await api.updateAppPreferences(state.appPreferences).catch(() => undefined);
scheduleDiscordPresenceUpdate();
let closeFlushStarted = false;
api.onPrepareToClose(async () => {
  if (closeFlushStarted) return;
  closeFlushStarted = true;
  if (clientConfigRenewalTimer) clearTimeout(clientConfigRenewalTimer);
  clientConfigRenewalTimer = null;
  releaseActiveServerStream({ stopPlayback: true });
  updateListeningSession();
  state.position = Number(audio.currentTime) || state.position || 0;
  try {
    await persist({ refreshSidebar: false });
    await Promise.race([
      syncListeningHistoryNow({ force: true }),
      new Promise((resolve) => setTimeout(resolve, 1500)),
    ]);
  } finally {
    api.readyToClose();
  }
});
accountSession = await api.loadAccountSession({ profileID: activeProfileID() }).catch(() => null);
if (accountSession) {
  state.serverURL = accountSession.baseURL;
  serverToken = String(accountSession.accessToken || "").trim();
  serverAdminToken = serverToken;
  if (accountSession.profileID) {
    state.syncProfiles = [{
      id: accountSession.profileID,
      name: safeAccountDisplayName(accountSession),
      is_default: true,
    }];
    await activateProfile(accountSession.profileID, accountSession.baseURL);
  }
} else {
  ({ clientToken: serverToken = "", adminToken: serverAdminToken = "" } = await api.loadServerCredentials());
  serverToken = serverToken.trim();
  serverAdminToken = serverAdminToken.trim();
}
api.onAccountSession(({ session, error }) => {
  void applyAccountSession(session, error).then(() => {
    if (!session || !state.serverURL) return;
    return refreshClientConfig({ force: true })
      .then(() => refreshProfiles())
      .then(() => serverAction("catalog"))
      .catch((failure) => { serverConnectionText = failure.message || "Connection failed"; });
  });
});
const localImportCapabilities = await api.localImportCapabilities().catch(() => ({ enabled: false }));
localImportAvailable = Boolean(localImportCapabilities?.enabled);
shuffle = Boolean(state.shuffle); repeat = Boolean(state.repeat);
state.volume = normalizedVolume(state.volume);
setPlaybackVolume(state.volume, { shouldPersist: false });
paintRange($("#seek"));
setCustomSelectValue($("#speed"), state.playbackRate || 1);
setCustomSelectValue($("#fullPlayerSpeed"), state.playbackRate || 1);
const initialVisibleTracks = tracksForActiveProfile(state);
const restoredCurrentID = state.currentTrackID && initialVisibleTracks.some((track) =>
  track.id === state.currentTrackID && track.available !== false) ? state.currentTrackID : null;
currentID = restoredCurrentID || initialVisibleTracks.find((track) => track.available !== false)?.id || null;
activePlaybackSourceQueueIDs = state.playbackSourceQueueIDs.length
  ? state.playbackSourceQueueIDs.filter((id) => initialVisibleTracks.some((track) => track.id === id && track.available !== false))
  : initialVisibleTracks.filter((track) => track.available !== false).map((track) => track.id);
activePlaybackQueueIDs = shuffle && state.playbackQueueIDs.length
  ? state.playbackQueueIDs.filter((id) => activePlaybackSourceQueueIDs.includes(id))
  : [...activePlaybackSourceQueueIDs];
activePlaybackPlaylistID = state.playbackPlaylistID;
if (currentID && !activePlaybackQueueIDs.includes(currentID)) activePlaybackQueueIDs.unshift(currentID);
state.playbackQueueIDs = [...activePlaybackQueueIDs];
state.playbackSourceQueueIDs = [...activePlaybackSourceQueueIDs];
if (currentID) {
  const track = currentTrack();
  pendingRestorePosition = restoredCurrentID ? Math.max(0, Number(state.position) || 0) : 0;
  if (!restoredCurrentID) state.position = 0;
  setAudioSource(track);
  audio.volume = playbackGainForVolume(state.volume);
  audio.playbackRate = Number(state.playbackRate) || 1;
}
if (libraryLoad?.warning) showNotice(libraryLoad.warning);
api.onTransferProgress((value) => {
  updateServerTransfer(value);
});
api.onLocalImportProgress((value) => {
  updateLocalImportTransfer(value);
});
function setUpdateStatus(message) {
  $("#updateStatus").textContent = message;
  const settingsStatus = $("#settingsUpdateStatus");
  if (settingsStatus) settingsStatus.textContent = message;
}

async function checkForUpdates() {
  setUpdateStatus("Checking for updates…");
  try {
    const result = await api.checkForUpdates();
    if (!result.supported) setUpdateStatus("Available in installed builds");
  } catch (error) {
    setUpdateStatus(error.message || "Update check failed");
  }
}

function syncWindowsUpdateBadge(value = {}) {
  const badge = $("#updateAvailableBadge");
  const detail = $("#updateAvailableDetail");
  const action = $("#updateAvailableAction");
  if (!badge || !detail || !action) return;

  if (value.version) availableWindowsUpdateVersion = value.version;
  if (value.type === "current") {
    availableWindowsUpdateVersion = null;
    dismissedWindowsUpdateVersion = null;
    windowsUpdateReady = false;
    badge.hidden = true;
    return;
  }
  const version = availableWindowsUpdateVersion;
  if (!version || dismissedWindowsUpdateVersion === version) {
    badge.hidden = true;
    return;
  }
  if (!["available", "downloading", "ready", "error"].includes(value.type)) return;

  badge.hidden = false;
  if (value.type === "ready") {
    windowsUpdateReady = true;
    detail.textContent = `Resonance ${version} is ready to install.`;
    action.textContent = "Restart to update";
    action.dataset.action = "install";
    action.disabled = false;
  } else if (value.type === "error") {
    windowsUpdateReady = false;
    detail.textContent = value.message || `Resonance ${version} could not finish downloading.`;
    action.textContent = "Try again";
    action.dataset.action = "retry";
    action.disabled = false;
  } else {
    windowsUpdateReady = false;
    detail.textContent = value.type === "downloading"
      ? `Downloading Resonance ${version}… ${Math.max(0, Math.min(100, Number(value.percent) || 0))}%`
      : `Resonance ${version} is available and downloading.`;
    action.textContent = "Downloading…";
    action.dataset.action = "downloading";
    action.disabled = true;
  }
}

function handleWindowsUpdateStatus(value = {}) {
  const install = $("#installUpdate");
  if (!install) return;
  syncWindowsUpdateBadge(value);
  if (value.type === "ready") {
    setUpdateStatus(`${value.version} downloaded`);
    install.hidden = false;
    install.disabled = false;
    return;
  }
  install.hidden = true;
  install.disabled = false;
  if (value.type === "checking") setUpdateStatus("Checking GitHub…");
  else if (value.type === "available") setUpdateStatus(`Downloading ${value.version}…`);
  else if (value.type === "downloading") setUpdateStatus(`Downloading… ${value.percent}%`);
  else if (value.type === "current") setUpdateStatus("You’re up to date");
  else if (value.type === "error") setUpdateStatus(value.message || "Update check failed");
}

async function installWindowsUpdate() {
  const install = $("#installUpdate");
  const badgeAction = $("#updateAvailableAction");
  install.disabled = true;
  badgeAction.disabled = true;
  setUpdateStatus("Restarting to finish the update…");
  $("#updateAvailableDetail").textContent = "Restarting Resonance to finish the update…";
  try {
    const started = await api.installUpdate();
    if (!started) {
      install.hidden = true;
      $("#updateAvailableBadge").hidden = true;
      setUpdateStatus("Available in installed builds");
    }
  } catch (error) {
    install.disabled = false;
    badgeAction.disabled = false;
    const message = error.message || "Could not install the update";
    setUpdateStatus(message);
    $("#updateAvailableDetail").textContent = message;
  }
}

api.onUpdateStatus(handleWindowsUpdateStatus);
try {
  const initialUpdateStatus = await api.getUpdateStatus();
  if (initialUpdateStatus?.type && initialUpdateStatus.type !== "idle") handleWindowsUpdateStatus(initialUpdateStatus);
} catch {
  // Automatic checking still reports through update:status in installed builds.
}
$("#checkForUpdates").onclick = checkForUpdates;
$("#installUpdate").onclick = installWindowsUpdate;
$("#updateAvailableAction").onclick = () => {
  if (windowsUpdateReady || $("#updateAvailableAction").dataset.action === "install") void installWindowsUpdate();
  else void checkForUpdates();
};
$("#dismissUpdateAvailable").onclick = () => {
  dismissedWindowsUpdateVersion = availableWindowsUpdateVersion;
  $("#updateAvailableBadge").hidden = true;
};
render(); updateChrome();
void refreshClientConfig().then(() => {
  persistInBackground({ refreshSidebar: false });
  if (section === "server") renderServer();
});
window.addEventListener("focus", () => {
  const activeConfig = activeServerClientConfig(clientConfig);
  const expiresSoon = activeConfig !== SAFE_CLIENT_CONFIG
    && Date.parse(activeConfig.expires_at) - Date.now() <= 90_000;
  if ((expiresSoon || activeConfig === SAFE_CLIENT_CONFIG) && (serverToken || serverAdminToken)) {
    void refreshClientConfig({ force: true }).then(() => {
      persistInBackground({ refreshSidebar: false });
      if (section === "server") renderServer();
    });
  }
});
syncPlaylistsNow({ automatic: true });
syncListeningHistoryNow();
setInterval(() => syncPlaylistsNow({ automatic: true }), 60000);
setInterval(() => syncListeningHistoryNow(), 60000);
