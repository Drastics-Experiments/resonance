import {
  applyRemotePlaylistDocument,
  createEmptyState,
  filterPlaylists,
  filterTracks,
  formatServerDownloadFailureNotice,
  formatHistoryWindowLabel,
  formatTime,
  mergePlaylistDocument,
  mergeSyncedTracks,
  nextIndex,
  niceChartMaximum,
  normalizedVolume,
  normalizeState,
  playbackRangeForTrack,
  reconcileUploadedTrack,
  removeClipRangeForTrack,
  resolveSyncProfile,
  restoreProfileState,
  storeActiveProfileState,
  setClipRangeForTrack,
  summarizeListeningHistory,
  summarizeListeningStats,
  trackBelongsToActiveProfile,
  tracksForActiveProfile,
  tracksForPlaylist,
  updatePlaylistRemoteSongIDs,
} from "./core.js";

const api = window.likedSongs;
const audio = document.querySelector("#audio");
const clipEditorPreviewAudio = document.querySelector("#clipEditorPreview");
const localImportPreviewAudio = document.querySelector("#localImportPreview");
const content = document.querySelector("#content");
let state = createEmptyState();
let currentID = null;
let section = "library";
let selectedPlaylistID = null;
let libraryFilter = "all";
let serverToken = "";
let serverAdminToken = "";
let serverCatalog = [];
const serverArtworkCache = new Map();
const serverArtworkPending = new Map();
let selectedRemoteIDs = new Set();
let shuffle = false;
let repeat = false;
let history = [];
let fullPlayerQueueTab = "up-next";
let activePlaybackQueueIDs = [];
let activePlaybackPlaylistID = null;
let pendingRestorePosition = null;
let playbackProgressTimer = null;
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
const FULL_PLAYER_TRANSITION_MS = 380;
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
let serverConnectInFlight = false;
let serverConnectPending = false;
let serverAutoAttempted = false;
let serverTransferActive = false;
let serverTransferCancelRequested = false;
let serverTransferOwner = null;
let draggingPlaylistTrackID = null;
let draggingPlaylistTargetID = null;
let draggingPlaylistInsertAfter = false;
let playlistDragPreviewKey = "";
let playlistDragFloatingRow = null;
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
let localImportResolvedSourceKey = null;
let localImportBatchContext = null;
const LOCAL_IMPORT_AUTO_RESOLVE_DELAY = 450;
let clipEditorStartSeconds = 0;
let clipEditorEndSeconds = 30;
let clipEditorPreviewEndSeconds = 0;
let clipEditorPreviewInterruptedPlayback = false;
let clipEditorPreviewLoading = false;
let clipEditorPreviewRequest = 0;
let clipBoundaryTrackID = null;
let profileGeneration = 0;
const activeProfileID = () => state.syncProfileID || "default";

const $ = (selector) => document.querySelector(selector);
const shuffleIcon = `<svg class="shuffle-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h2.5a5 5 0 0 1 4 2l5 7a5 5 0 0 0 4 2H21"/><path d="m17 13 4 4-4 4"/><path d="M3 18h2.5a5 5 0 0 0 4-2l5-7a5 5 0 0 1 4-2H21"/><path d="m17 3 4 4-4 4"/></svg>`;
const plusIcon = `<svg class="plus-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>`;
const checkIcon = `<svg class="check-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="m5 12.5 4.3 4.3L19 7"/></svg>`;
const playbackPlayIcon = `<svg class="transport-icon" viewBox="0 0 24 24" aria-hidden="true"><path class="icon-fill" d="M8 5v14l11-7z"/></svg>`;
const playbackPauseIcon = `<svg class="transport-icon" viewBox="0 0 24 24" aria-hidden="true"><rect class="icon-fill" x="6" y="5" width="4.5" height="14" rx="1.5"/><rect class="icon-fill" x="13.5" y="5" width="4.5" height="14" rx="1.5"/></svg>`;
const nowPlayingIcon = `<svg class="now-playing-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M3.5 9.5h4l5-4v13l-5-4h-4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7"/><path d="M18.5 5.5a9 9 0 0 1 0 13"/></svg>`;
const serverUploadIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 16V4m0 0L7.5 8.5M12 4l4.5 4.5"/><path d="M5 14v5h14v-5"/></svg>`;
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
  controller.value.textContent = selectedOption?.label || "Choose…";
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
  window.addEventListener("scroll", () => customSelectControllers.forEach(positionCustomSelect), true);
}

const currentTrack = () => state.tracks.find((track) => track.id === currentID && trackBelongsToActiveProfile(state, track)) || null;
const playlistTracks = () => (selectedPlaylistID ? tracksForPlaylist(state, selectedPlaylistID) : tracksForActiveProfile(state))
  .filter((track) => trackBelongsToActiveProfile(state, track));
const activeRemoteTrack = (remoteID) => state.tracks.find((track) => track.remoteID === remoteID && trackBelongsToActiveProfile(state, track));
const activeProfile = () => state.syncProfiles.find((profile) => profile.id === activeProfileID())
  || state.syncProfiles.find((profile) => profile.id === "default")
  || { id: "default", name: "Default" };

function activePlaybackTracks() {
  return activePlaybackQueueIDs
    .map((id) => state.tracks.find((track) => track.id === id && trackBelongsToActiveProfile(state, track)))
    .filter(Boolean);
}

function setPlaybackContext(tracks, playlistID) {
  activePlaybackQueueIDs = [...new Set(tracks.map((track) => track.id))];
  activePlaybackPlaylistID = typeof playlistID === "string" ? playlistID : null;
  state.playbackQueueIDs = [...activePlaybackQueueIDs];
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

function updateProfileControl() {
  const control = $("#profileControl");
  const button = $("#profileButton");
  if (!control || !button) return;
  const name = String(activeProfile().name || "Default").trim() || "Default";
  control.hidden = false;
  button.title = `Profile: ${name}`;
  button.setAttribute("aria-label", `Open profile menu for ${name}`);
  const initial = Array.from(name)[0]?.toLocaleUpperCase() || "D";
  $("#profileInitial").textContent = initial;
  $("#profileMenuInitial").textContent = initial;
  $("#profileMenuName").textContent = name;
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

function clipEditorWaveBars(track) {
  const seed = Array.from(`${track?.id || "resonance"}${track?.title || "clip"}`)
    .reduce((total, character) => total + character.codePointAt(0), 0);
  const phase = (seed % 31) / 6;
  let randomState = seed || 1;
  let previousAmplitude = .58;
  return Array.from({ length: 112 }, (_, index) => {
    randomState = (randomState * 1664525 + 1013904223) >>> 0;
    const noise = randomState / 0xffffffff;
    previousAmplitude = previousAmplitude * .54 + noise * .46;
    const envelope = .58
      + Math.sin(index * .083 + phase) * .16
      + Math.sin(index * .029 + phase * .41) * .11;
    const amplitude = previousAmplitude * .62 + envelope * .38;
    const height = 22 + Math.round(Math.max(.12, Math.min(1, amplitude)) * 74);
    return `<i class="wave-level-${Math.max(2, Math.min(9, Math.round(height / 10)))}"></i>`;
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
    void stopClipRangePreview();
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
}

function renderClipEditorTrack({ resetRange = false } = {}) {
  const track = clipEditorTrack();
  const workspace = $("#clipEditorWorkspace");
  const empty = $("#clipEditorEmpty");
  workspace.hidden = !track;
  empty.hidden = Boolean(track);
  $("#saveClipRange").disabled = !track;
  $("#previewClipRange").disabled = !track?.fileUrl;
  if (!track) {
    $("#clearClipRange").hidden = true;
    $("#clipEditorStatus").textContent = "Import or download a song before setting a clip range.";
    return;
  }
  const duration = clipEditorDuration(track);
  $("#clipEditorTrackTitle").textContent = track.title || "Unknown title";
  $("#clipEditorTrackMeta").textContent = `${track.artist || "Unknown Artist"} · ${displayAlbum(track)}`;
  $("#clipEditorTrackDuration").textContent = formatTime(duration);
  $("#clipEditorArtwork").innerHTML = track.artwork ? `<img src="${escapeHTML(track.artwork)}" alt="">` : "♪";
  $("#clipEditorWaveBars").innerHTML = clipEditorWaveBars(track);
  if (resetRange) {
    const savedRange = playbackRangeForTrack(state, track);
    const defaultStart = duration > 60 ? 15 : 0;
    clipEditorStartSeconds = savedRange?.startSeconds ?? defaultStart;
    clipEditorEndSeconds = savedRange?.endSeconds ?? Math.min(duration, defaultStart + 45);
  }
  updateClipEditorRange();
  const savedRange = playbackRangeForTrack(state, track);
  $("#clearClipRange").hidden = !savedRange;
  $("#clipEditorStatus").textContent = savedRange
    ? `This profile plays ${formatTime(savedRange.startSeconds)}–${formatTime(savedRange.endSeconds)}. The song file is unchanged.`
    : "Choose a range. The song file is never changed.";
}

function syncClipRangePreviewButton() {
  const button = $("#previewClipRange");
  const playing = !clipEditorPreviewAudio.paused && !clipEditorPreviewAudio.ended;
  button.classList.toggle("playing", playing);
  button.setAttribute("aria-pressed", String(playing));
  button.disabled = clipEditorPreviewLoading || !clipEditorTrack()?.fileUrl;
  button.innerHTML = clipEditorPreviewLoading
    ? '<span>Preparing…</span>'
    : playing
    ? '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="7" y="7" width="10" height="10" rx="1.5"></rect></svg><span>Stop</span>'
    : '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5v14l11-7z"></path></svg><span>Preview</span>';
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

async function resumePlaybackAfterClipRangePreview() {
  if (!clipEditorPreviewInterruptedPlayback) return;
  clipEditorPreviewInterruptedPlayback = false;
  if (currentTrack() && audio.paused) await requestPlayback();
}

async function stopClipRangePreview({ resumeMain = true } = {}) {
  const wasActive = clipEditorPreviewLoading || Boolean(clipEditorPreviewAudio.getAttribute("src"));
  clipEditorPreviewRequest += 1;
  clipEditorPreviewLoading = false;
  clipEditorPreviewAudio.pause();
  clipEditorPreviewAudio.removeAttribute("src");
  clipEditorPreviewAudio.load();
  clipEditorPreviewEndSeconds = 0;
  syncClipRangePreviewButton();
  if (wasActive && $("#clipEditorDialog").open) {
    $("#clipEditorStatus").textContent = "Preview stopped. This does not save the range.";
  }
  if (resumeMain) await resumePlaybackAfterClipRangePreview();
  else clipEditorPreviewInterruptedPlayback = false;
}

async function toggleClipRangePreview() {
  if (!clipEditorPreviewAudio.paused) {
    await stopClipRangePreview();
    return;
  }
  const track = clipEditorTrack();
  if (!track?.fileUrl) return;
  await stopClipRangePreview();
  const request = ++clipEditorPreviewRequest;
  clipEditorPreviewLoading = true;
  syncClipRangePreviewButton();
  if (!audio.paused) {
    clipEditorPreviewInterruptedPlayback = true;
    audio.pause();
  }
  const status = $("#clipEditorStatus");
  try {
    clipEditorPreviewAudio.src = track.fileUrl;
    clipEditorPreviewAudio.volume = normalizedVolume(state.volume);
    await waitForClipRangePreviewMetadata();
    if (request !== clipEditorPreviewRequest) return;
    clipEditorPreviewAudio.currentTime = clipEditorStartSeconds;
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
    }
  }
}

function openClipEditor() {
  closeProfileMenu();
  const select = $("#clipEditorTrack");
  const visibleTracks = tracksForActiveProfile(state);
  const preferredTrack = visibleTracks.find((track) => track.id === currentID) || visibleTracks[0];
  setCustomSelectOptions(select, visibleTracks.map((track) => ({
    value: track.id,
    label: `${track.title} — ${track.artist || "Unknown Artist"}`,
  })), preferredTrack?.id);
  renderClipEditorTrack({ resetRange: true });
  $("#clipEditorDialog").showModal();
  requestAnimationFrame(() => (preferredTrack ? customSelectControllers.get(select)?.trigger : $("#closeClipEditor"))?.focus());
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
    const range = setClipRangeForTrack(state, track, clipEditorStartSeconds, clipEditorEndSeconds);
    if (!range) throw new Error("Choose a valid clip range.");
    clipRangeMutationGeneration += 1;
    if (currentID === track.id && (audio.currentTime < range.startSeconds || audio.currentTime >= range.endSeconds)) {
      audio.currentTime = range.startSeconds;
      state.position = range.startSeconds;
    }
    await persist();
    if (track.remoteID) schedulePlaylistSync();
    $("#clearClipRange").hidden = false;
    const profileName = state.syncProfiles.find((profile) => profile.id === activeProfileID())?.name || activeProfileID();
    status.textContent = track.remoteID
      ? `Saved for ${profileName}. Syncing this range to the server…`
      : `Saved for ${profileName} on this device. Upload the song to sync its range.`;
    showNotice(`Playback for “${track.title}” is now limited to ${formatTime(range.startSeconds)}–${formatTime(range.endSeconds)}.`, "status");
  } catch (error) {
    status.textContent = error.message || "Resonance could not save this clip range.";
  } finally {
    button.disabled = false;
    button.textContent = "Save range";
  }
}

async function clearClipRange() {
  const track = clipEditorTrack();
  if (!track || !removeClipRangeForTrack(state, track)) return;
  await stopClipRangePreview();
  clipRangeMutationGeneration += 1;
  await persist();
  if (track.remoteID) schedulePlaylistSync();
  clipEditorStartSeconds = 0;
  clipEditorEndSeconds = clipEditorDuration(track);
  renderClipEditorTrack();
  $("#clipEditorStatus").textContent = "This profile now plays the full song. The song file is unchanged.";
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
  const songs = summary.songSeries
    .map((series) => {
      const activity = series.days[dayIndex];
      const track = state.tracks.find((item) => item.id === series.trackID);
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
    const title = track?.title || "Removed song";
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
    const topTrack = top && state.tracks.find((track) => track.id === top.series.trackID);
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
  const topTrack = state.tracks.find((track) => track.id === allTimeStats.topTrackID);
  const rankedSongs = allTimeStats.songRanking.map((song, index) => {
    const track = state.tracks.find((item) => item.id === song.trackID);
    const title = track?.title || "Removed song";
    const artist = track?.artist || "Unknown artist";
    return `<article class="history-ranked-song" data-history-track="${escapeHTML(song.trackID)}" tabindex="0" aria-keyshortcuts="Shift+F10">
      <span class="history-ranked-position">#${index + 1}</span>
      ${artwork(track)}
      <strong title="${escapeHTML(title)}">${escapeHTML(title)}</strong>
      <small title="${escapeHTML(artist)}">${escapeHTML(artist)}</small>
      <em>${escapeHTML(historyListenedTime(song.seconds))} · ${song.plays.toLocaleString()} ${song.plays === 1 ? "play" : "plays"}</em>
    </article>`;
  }).join("");
  const topSongTitle = topTrack?.title || (allTimeStats.topTrackID ? "Removed song" : "No listening yet");
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

function beginListeningSession() {
  const track = currentTrack();
  if (!track) return;
  const activeEntry = state.listeningHistory.find((entry) => entry.id === activeListeningEntryID);
  if (activeEntry?.trackID === track.id) return;
  const entry = {
    id: crypto.randomUUID(),
    trackID: track.id,
    profileID: activeProfileID(),
    startedAt: new Date().toISOString(),
    listenedSeconds: 0,
  };
  state.listeningHistory = [...state.listeningHistory, entry].slice(-2000);
  activeListeningEntryID = entry.id;
  lastListeningPosition = Number(audio.currentTime) || 0;
  lastPersistedListeningSeconds = 0;
  persistInBackground();
}

function updateListeningSession() {
  const entry = state.listeningHistory.find((item) => item.id === activeListeningEntryID);
  const position = Number(audio.currentTime) || 0;
  if (!entry) {
    lastListeningPosition = position;
    return;
  }
  const delta = position - lastListeningPosition;
  if (!audio.paused && delta > 0 && delta < 5) entry.listenedSeconds += delta;
  lastListeningPosition = position;
  if (entry.listenedSeconds - lastPersistedListeningSeconds >= 15) {
    lastPersistedListeningSeconds = entry.listenedSeconds;
    persistInBackground();
    scheduleListeningHistorySync();
    if ($("#listeningHistoryDialog").open) renderListeningHistory();
  }
}

function pendingListeningHistoryBatches() {
  const baseKey = normalizedServerKey(state.serverURL);
  const tracksByID = new Map(state.tracks.map((track) => [track.id, track]));
  const entriesByProfile = new Map();
  const optionalText = (value, maximumLength) => {
    const text = typeof value === "string" ? value.trim() : "";
    return text ? text.slice(0, maximumLength) : null;
  };
  for (const entry of state.listeningHistory) {
    const listenedSeconds = Math.max(0, Number(entry.listenedSeconds) || 0);
    if (listenedSeconds <= 0 || listenedSeconds > 31 * 24 * 60 * 60) continue;
    if (!entry.id || entry.id.length > 128 || !entry.trackID || entry.trackID.length > 128) continue;
    const profileID = entry.profileID || "default";
    const syncKey = `${baseKey}#profile=${profileID}#event=${entry.id}`;
    if ((listeningHistorySyncedSeconds.get(syncKey) || 0) >= listenedSeconds) continue;
    const track = tracksByID.get(entry.trackID);
    const duration = Number(track?.duration);
    const upload = {
      syncKey,
      listenedSeconds,
      entry: {
        id: entry.id,
        trackID: entry.trackID,
        remoteID: optionalText(track?.remoteID, 128),
        startedAt: entry.startedAt,
        listenedSeconds,
        title: optionalText(track?.title, 500),
        artist: optionalText(track?.artist, 500),
        album: optionalText(track?.album, 500),
        duration: Number.isFinite(duration) && duration >= 0 && duration <= 7 * 24 * 60 * 60 ? duration : null,
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
    let batches;
    try {
      batches = pendingListeningHistoryBatches();
    } catch {
      return false;
    }
    for (const batch of batches) {
      try {
        const result = await api.postListeningHistory({
          baseURL: state.serverURL,
          token: serverToken,
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

function closeSearchSort() {
  $("#searchSort").classList.remove("open");
  $("#searchSortButton").setAttribute("aria-expanded", "false");
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
  url.hash = "";
  url.search = "";
  url.pathname = url.pathname.replace(/\/+$/, "") + "/";
  return url.href;
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

function markPlaylistDirty(playlist) {
  if (!playlist || playlist.isSystem) return;
  playlistMutationGeneration += 1;
  const id = playlist.id.toLocaleLowerCase();
  state.dirtyPlaylistIDs = [...new Set([...state.dirtyPlaylistIDs, id])];
  state.deletedPlaylistIDs = state.deletedPlaylistIDs.filter((item) => item !== id);
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
      if (!automatic) showNotice("Enter the server access token.");
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
    return `<div class="row-art">${source ? `<img src="${escapeHTML(source)}" alt="">` : "♪"}</div>`;
  }
  return `<div class="row-art server-artwork-loading${canRenderImage ? " has-image" : ""}" data-server-artwork-id="${escapeHTML(track?.id || "")}" aria-busy="true">
    <span class="server-artwork-placeholder" aria-hidden="true">♪</span>
    ${canRenderImage ? `<img src="${escapeHTML(source)}" alt="">` : ""}
  </div>`;
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
    <span class="recent-track-art">${track?.artwork ? `<img src="${escapeHTML(track.artwork)}" alt="">` : "<span aria-hidden=\"true\">♪</span>"}<span class="recent-track-play" aria-hidden="true">${playbackPlayIcon}</span></span>
    <span class="recent-track-copy"><strong>${escapeHTML(title)}</strong><small>${escapeHTML(artist)}</small></span>
  </button>`;
}

function trackRow(track, index) {
  const liked = state.favorites.includes(track.id);
  const editablePlaylist = state.playlists.find((playlist) => playlist.id === selectedPlaylistID && !playlist.isSystem);
  const actionLabel = `Play ${track.title || "Untitled"} by ${track.artist || "Unknown artist"}`;
  const reorderLabel = editablePlaylist ? ". Press Alt+Up or Alt+Down to reorder" : "";
  const draggableAttributes = editablePlaylist
    ? ` draggable="true" data-playlist-draggable="true" aria-keyshortcuts="Alt+ArrowUp Alt+ArrowDown Shift+F10"`
    : ` aria-keyshortcuts="Enter Space Shift+F10"`;
  return `<div class="track-row ${track.id === currentID ? "playing" : ""}${editablePlaylist ? " playlist-draggable" : ""}" data-track="${track.id}" tabindex="0" aria-label="${escapeHTML(actionLabel + reorderLabel)}"${draggableAttributes}>
    <span class="track-number" title="${track.id === currentID && !audio.paused ? "Now playing" : `Track ${index + 1}`}">${track.id === currentID && !audio.paused ? nowPlayingIcon : index + 1}</span>${artwork(track)}
    <div class="track-copy"><strong>${escapeHTML(track.title)}</strong><small>${escapeHTML(track.artist)} / Audio</small></div>
    <span class="album">${escapeHTML(displayAlbum(track))}</span><span class="track-time">${formatTime(track.duration)}</span>
    <button type="button" class="heart" data-favorite="${track.id}" aria-label="${liked ? "Remove from" : "Add to"} Liked Songs" aria-pressed="${liked}">${liked ? "♥" : "♡"}</button>
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
  const recentTracks = !selectedPlaylistID ? filterTracks(tracks, "", "recent") : [];
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
    ? `<div class="playlist-action-cluster"><button class="${shuffle ? "active" : ""}" id="heroShuffle" title="Shuffle" aria-label="Shuffle" aria-pressed="${shuffle}" ${tracks.length ? "" : "disabled"}>${shuffleIcon}</button><button id="heroAdd" title="Add songs" aria-label="Add songs">${plusIcon}</button>${playlistMoreMenu}</div>`
    : "";
  const libraryFilters = `<div class="filters${selectedPlaylistID ? "" : " library-top-filters"}" role="group" aria-label="Library filter"><button class="${libraryFilter === "all" ? "active" : ""}" data-library-filter="all" aria-pressed="${libraryFilter === "all"}">All songs</button><button class="${libraryFilter === "recent" ? "active" : ""}" data-library-filter="recent" aria-pressed="${libraryFilter === "recent"}">Recently added</button><button class="${libraryFilter === "audio" ? "active" : ""}" data-library-filter="audio" aria-pressed="${libraryFilter === "audio"}">Audio</button></div>`;
  const hasLibraryFilter = Boolean(libraryQuery.trim()) || libraryFilter !== "all";
  const emptyLibraryTitle = hasLibraryFilter ? "No matching songs" : selectedPlaylistID ? "This playlist is empty" : "No songs yet";
  const emptyLibraryHelp = hasLibraryFilter ? "Try another search or filter." : selectedPlaylistID ? "Like songs or add them from your Library." : "Import audio files or connect your music server.";
  const collectionHeader = selectedPlaylistID
    ? `<div class="hero"><div class="hero-art">≋</div><div><span class="eyebrow">PLAYLIST</span><h1>${escapeHTML(title)}</h1><p>${tracks.length} tracks / Stored locally</p><div class="hero-actions"><button class="primary playlist-play" id="playCollection" ${tracks.length ? "" : "disabled"}><span class="button-icon">${collectionPlaying ? playbackPauseIcon : playbackPlayIcon}</span><span>${collectionPlaying ? "Pause" : "Play"}</span></button>${playlistCapsule}</div></div></div>`
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
    else if (tracks[0]) play(tracks[0], tracks, { playlistID: selectedPlaylistID });
  };
  if ($("#heroShuffle")) $("#heroShuffle").onclick = () => {
    shuffle = !shuffle;
    state.shuffle = shuffle;
    persistInBackground();
    updateChrome();
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
  content.innerHTML = `<div class="page"><span class="eyebrow">YOUR COLLECTIONS</span><h1>Playlists</h1><p>Organize your music into collections shared across your Resonance devices.</p><div class="playlist-page-actions"><button class="primary" id="pageNewPlaylist">＋ New Playlist</button><button class="secondary" id="pageSyncPlaylists">Sync Playlists</button></div><div class="playlist-grid">${playlists.map((playlist) => `<button class="playlist-card" data-open-playlist="${playlist.id}" aria-keyshortcuts="Shift+F10"><div class="playlist-art">${playlist.isSystem ? "♥" : "♪"}</div><div><strong>${escapeHTML(playlist.name)}</strong><small>${playlist.trackIDs.length} tracks</small></div><span>›</span></button>`).join("") || `<div class="empty"><b>No matching playlists</b><span>Try a different playlist or song name.</span></div>`}</div></div>`;
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
    if (storageScope === "downloads" && !track.remoteID) return false;
    if (storageScope === "files" && track.remoteID) return false;
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
  const deleted = [];
  const failed = [];
  for (const track of tracks) {
    try {
      await api.deleteAudio(track.filePath);
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
  state.playbackQueueIDs = [...activePlaybackQueueIDs];
  if (removed.has(currentID)) {
    audio.pause();
    audio.removeAttribute("src");
    currentID = null;
    state.currentTrackID = null;
    state.position = 0;
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
  const localTracks = visibleTracks.filter((track) => !track.remoteID);
  const remoteTracks = visibleTracks.filter((track) => track.remoteID);
  const localBytes = localTracks.reduce((sum, track) => sum + (track.size || 0), 0);
  const remoteBytes = remoteTracks.reduce((sum, track) => sum + (track.size || 0), 0);
  const total = Math.max(localBytes + remoteBytes, 1);
  const localDegrees = Math.round(localBytes / total * 360);
  const storageHasQuery = Boolean(storageQuery.trim());
  const storageEmptyTitle = storageHasQuery ? "No matching songs" : storageScope === "downloads" ? "No server downloads yet" : storageScope === "files" ? "No imported files yet" : "No songs stored yet";
  const storageEmptyHelp = storageHasQuery ? "Try another search." : storageScope === "downloads" ? "Download songs from Music Server to keep them on this device." : "Import audio files to add them to this device.";
  content.innerHTML = `<div class="page storage-page"><div class="page-title-row"><div><span class="eyebrow">ON THIS DEVICE</span><h1>Song Storage</h1></div><div class="page-title-actions"><div class="storage-import-control" id="storageImportControl"><button class="primary storage-import-trigger" id="storageImportMenuButton" type="button" aria-haspopup="menu" aria-expanded="false" aria-controls="storageImportMenu"><span class="button-icon" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M12 3v11m0 0 4-4m-4 4-4-4M5 16v3h14v-3"/></svg></span><span>Import</span><svg class="storage-import-chevron" viewBox="0 0 16 16" aria-hidden="true"><path d="m4 6 4 4 4-4"/></svg></button><div class="storage-import-menu" id="storageImportMenu" role="menu" aria-label="Choose an import type" hidden>${localImportAvailable ? '<button class="storage-import-option" type="button" role="menuitem" data-storage-import="link"><span class="storage-import-option-icon" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M14 4h6v6M20 4l-9 9M10 6H6a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-4"/></svg></span><span><strong>Import from link</strong><small>Spotify or YouTube URL</small></span></button>' : ""}<button class="storage-import-option" type="button" role="menuitem" data-storage-import="files"><span class="storage-import-option-icon" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M4 7.5h6l2-2h8v13H4zM12 10v6m-3-3h6"/></svg></span><span><strong>Import files</strong><small>Choose audio from this device</small></span></button></div></div><button class="secondary" id="storageEdit" ${!storageEditing && !tracks.length ? "disabled" : ""}>${storageEditing ? "Done" : "Edit"}</button></div></div>
    <div class="storage-summary" id="storageSummary"><div class="storage-ring" style="--local:${localDegrees}deg"><span>♪</span></div><div class="storage-stat"><small>Local audio</small><strong>${formatBytes(localBytes)}</strong><span>${localTracks.length} files</span></div><div class="storage-stat"><small>Server downloads</small><strong>${formatBytes(remoteBytes)}</strong><span>${remoteTracks.length} files</span></div><div class="storage-stat"><small>Available</small><strong id="storageAvailable">Calculating…</strong><span id="storageFreePercent">Disk space</span></div></div>
    <div class="segmented storage-tabs" role="group" aria-label="Storage scope"><button class="${storageScope === "songs" ? "active" : ""}" data-storage-scope="songs" aria-pressed="${storageScope === "songs"}">Songs</button><button class="${storageScope === "downloads" ? "active" : ""}" data-storage-scope="downloads" aria-pressed="${storageScope === "downloads"}">Downloads</button><button class="${storageScope === "files" ? "active" : ""}" data-storage-scope="files" aria-pressed="${storageScope === "files"}">Files</button></div>
    ${storageEditing ? `<div class="selection-bar"><span>${selectedStorageIDs.size} selected</span><button class="danger" id="deleteSelectedStorage" ${selectedStorageIDs.size ? "" : "disabled"}>Delete selected</button></div>` : ""}
    <div class="storage-section-heading"><strong>${storageScope === "downloads" ? "DOWNLOADED FROM SERVER" : storageScope === "files" ? "IMPORTED ON THIS PC" : "ALL SONGS"}</strong><span>${tracks.length} songs</span></div>
    <div class="storage-list redesigned">${tracks.map((track) => `<div class="storage-row ${storageEditing ? "selecting" : ""}" data-storage-track="${track.id}" tabindex="0" aria-keyshortcuts="Shift+F10"><button class="storage-select ${selectedStorageIDs.has(track.id) ? "selected" : ""}" data-storage-select="${track.id}" aria-label="${selectedStorageIDs.has(track.id) ? "Deselect" : "Select"} ${escapeHTML(track.title || "song")}" aria-pressed="${selectedStorageIDs.has(track.id)}" ${storageEditing ? "" : "hidden"}>${selectedStorageIDs.has(track.id) ? "✓" : "○"}</button>${artwork(track)}<span class="track-details"><strong>${escapeHTML(track.title)}</strong><small>${escapeHTML(track.artist || "Unknown Artist")} • ${escapeHTML(displayAlbum(track))}</small></span><span class="storage-size">${formatBytes(track.size)}</span><button class="row-menu" data-storage-menu="${track.id}" title="More options" aria-label="More options for ${escapeHTML(track.title || "song")}">•••</button></div>`).join("") || `<div class="empty"><b>${storageEmptyTitle}</b><span>${storageEmptyHelp}</span></div>`}</div></div>`;
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
    const available = $("#storageAvailable");
    const percent = $("#storageFreePercent");
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

function renderServer() {
  updateTopSearch();
  const downloaded = serverCatalog.filter((song) => activeRemoteTrack(song.id)).length;
  const filteredCount = filteredServerCatalog().length;
  const playlistCount = state.playlists.filter((playlist) => !playlist.isSystem).length;
  const connected = serverConnected;
  const showConnectionDetail = !connected || !serverConnectionText.startsWith("Connected •");
  const selectLabel = serverSelecting ? "Cancel song selection" : "Choose songs to download";
  const downloadLabel = serverSelecting
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
    <div class="server-library-bar"><div><strong>${resultSummary}</strong></div><div class="server-actions">
      <button id="uploadServer" title="Upload songs" aria-label="Upload songs">${serverUploadIcon}</button>
      <button id="syncAll" title="${downloadLabel}" aria-label="${downloadLabel}" ${serverSelecting && !selectedRemoteIDs.size ? "disabled" : ""}>${serverDownloadIcon}</button>
      <button id="syncSelected" class="${serverSelecting ? "active" : ""}" title="${selectLabel}" aria-label="${selectLabel}" aria-pressed="${serverSelecting}">${serverSelecting ? `<b>${selectedRemoteIDs.size}</b>` : serverSelectIcon}</button>
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
  $("#uploadServer").onclick = uploadServerSongs;
  $("#syncServerPlaylists").onclick = () => syncPlaylistsNow();
  bindServerArtworkLoadStates();
  bindRemoteRows();
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
    return `<div class="remote-row ${serverSelecting ? "selecting" : ""} ${selected ? "selected" : ""}" data-remote-row="${song.id}" tabindex="0" aria-keyshortcuts="Shift+F10">
      <button class="remote-check ${selected ? "selected" : ""}" data-select-remote="${song.id}" ${serverSelecting ? "" : "hidden"} aria-label="${selected ? "Deselect" : "Select"} ${escapeHTML(song.title || song.name)}">${selected ? "✓" : ""}</button>
      ${artwork(song, { animateLoading: true })}
      <span class="server-song-title"><strong>${escapeHTML(song.title || song.name)}</strong>${onDevice ? '<small>On device</small>' : ""}</span>
      <span class="server-cell">${escapeHTML(song.artist || "Unknown Artist")}</span>
      <span class="server-cell server-album">${escapeHTML(displayAlbum(song))}</span>
      <span class="server-cell server-duration">${duration}</span>
      <button class="row-menu" data-remote-menu="${song.id}" title="More options" aria-label="More options for ${escapeHTML(song.title || song.name)}">•••</button>
    </div>`;
  }).join("");
}

function bindRemoteRows() {
  document.querySelectorAll("[data-select-remote]").forEach((button) => button.onclick = () => { selectedRemoteIDs.has(button.dataset.selectRemote) ? selectedRemoteIDs.delete(button.dataset.selectRemote) : selectedRemoteIDs.add(button.dataset.selectRemote); renderServer(); });
  document.querySelectorAll("[data-remote-row]").forEach((row) => {
    row.onclick = (event) => {
      if (!serverSelecting || event.target.closest("button")) return;
      const id = row.dataset.remoteRow;
      selectedRemoteIDs.has(id) ? selectedRemoteIDs.delete(id) : selectedRemoteIDs.add(id);
      renderServer();
    };
    row.oncontextmenu = (event) => openServerTrackContextMenu(event, row.dataset.remoteRow);
    row.onkeydown = (event) => {
      if (event.target !== row) return;
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
  const token = $("#serverToken")?.value || serverToken;
  if (!url || !token) return;
  const response = await api.fetchProfiles({ baseURL: url, token });
  state.syncProfiles = response.profiles || [];
  const resolution = resolveSyncProfile(state.syncProfiles, activeProfileID(), response.default_profile_id);
  if (resolution.profile && resolution.profile.id !== activeProfileID()) {
    await activateProfile(resolution.profile.id);
  }
  renderProfileOptions(resolution.profile?.id || activeProfileID());
}

function updateProfileSwitchDialog({ resetQuery = true } = {}) {
  const profile = activeProfile();
  const name = String(profile.name || "Default").trim() || "Default";
  const initial = Array.from(name)[0]?.toLocaleUpperCase() || "D";
  $("#profileSwitchInitial").textContent = initial;
  $("#profileSwitchCurrentName").textContent = name;
  if (resetQuery) $("#profileSwitchQuery").value = name;
}

function matchingSyncProfile(query) {
  const key = String(query || "").trim().toLocaleLowerCase();
  if (!key) return null;
  return state.syncProfiles.find((profile) =>
    String(profile.id || "").toLocaleLowerCase() === key
    || String(profile.name || "").toLocaleLowerCase() === key) || null;
}

function updateProfileSwitchActions({ busy = false } = {}) {
  const query = $("#profileSwitchQuery").value.trim();
  const current = matchingSyncProfile(query);
  const connected = Boolean(state.serverURL && serverToken);
  $("#createProfileFromSwitcher").disabled = busy || !connected || !query || Boolean(current);
  $("#confirmProfileSwitch").disabled = busy || !connected || !query || current?.id === activeProfileID();
  if (busy) return;
  const status = $("#profileSwitchStatus");
  if (!connected) status.textContent = "Not connected";
  else if (current?.id === activeProfileID()) status.textContent = "Current profile";
  else if (current) status.textContent = "Existing profile";
  else status.textContent = "New profile name";
}

async function openProfileSwitcher() {
  closeProfileMenu();
  updateProfileSwitchDialog();
  const dialog = $("#profileSwitchDialog");
  const status = $("#profileSwitchStatus");
  dialog.showModal();
  $("#profileSwitchQuery").focus();
  $("#profileSwitchQuery").select();
  if (!state.serverURL || !serverToken) {
    updateProfileSwitchActions();
    return;
  }
  status.textContent = "Checking server profiles…";
  updateProfileSwitchActions({ busy: true });
  try {
    const response = await api.fetchProfiles({ baseURL: state.serverURL, token: serverToken });
    state.syncProfiles = response.profiles || [];
    renderProfileOptions();
    updateProfileSwitchDialog({ resetQuery: false });
    updateProfileSwitchActions();
  } catch (error) {
    status.textContent = error.message || "Could not load profiles";
    $("#createProfileFromSwitcher").disabled = true;
    $("#confirmProfileSwitch").disabled = true;
  }
}

async function activateProfile(profileID, serverURL = state.serverURL) {
  if (!profileID) return;
  const targetServerKey = normalizedServerKey(serverURL);
  if (profileID === activeProfileID() && targetServerKey === normalizedServerKey(state.serverURL)) return;
  storeActiveProfileState(state);
  restoreProfileState(state, profileID, serverURL);
  profileGeneration += 1;
  if (playlistSyncInFlight) playlistSyncPending = true;
  if (serverConnectInFlight) serverConnectPending = true;
  serverConnected = false;
  serverCatalog = [];
  selectedRemoteIDs.clear();
  selectedPlaylistID = null;
  const visibleTrackIDs = new Set(tracksForActiveProfile(state).map((track) => track.id));
  activePlaybackQueueIDs = activePlaybackQueueIDs.filter((id) => visibleTrackIDs.has(id));
  state.playbackQueueIDs = [...activePlaybackQueueIDs];
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
}

async function openServerSettings() {
  $("#serverURL").value = state.serverURL || "";
  $("#serverToken").value = serverToken;
  $("#serverAdminToken").value = serverAdminToken;
  renderProfileOptions();
  $("#serverSettingsDialog").showModal();
  try { await refreshProfiles(); } catch { /* connection fields may still be incomplete */ }
}

async function saveServerForm() {
  const nextServerURL = $("#serverURL")?.value.trim() || state.serverURL;
  serverToken = $("#serverToken")?.value || serverToken;
  serverAdminToken = $("#serverAdminToken")?.value || serverAdminToken;
  await activateProfile($("#syncProfile")?.value || activeProfileID(), nextServerURL);
  await api.saveServerCredentials({ clientToken: serverToken, adminToken: serverAdminToken });
  await persist();
  updateProfileControl();
  schedulePlaylistSync();
  scheduleListeningHistorySync();
}

function renderSettings() {
  updateTopSearch();
  const profile = activeProfile();
  const track = currentTrack();
  content.innerHTML = `<div class="page settings-page">
    <span class="eyebrow">RESONANCE</span><h1>Settings</h1><p>Manage this device, your music server, playback tools, and updates.</p>
    <div class="settings-grid">
      <section class="settings-card"><span class="settings-card-icon" aria-hidden="true">${serverDeviceIcon}</span><div><h2>Music Server</h2><p>${serverConnected ? "Connected" : "Not connected"} · ${escapeHTML(profile.name || "Default")}</p><small>${escapeHTML(state.serverURL || "No server configured")}</small></div><button id="settingsServer" class="secondary" type="button">Connection settings</button></section>
      <section class="settings-card"><span class="settings-card-icon" aria-hidden="true">${historyClockIcon}</span><div><h2>Listening & clips</h2><p>${track ? escapeHTML(track.title) : "Nothing selected"}</p><small>${Math.round(audio.volume * 100)}% volume · ${audio.playbackRate || 1}× speed</small></div><div class="settings-card-actions"><button id="settingsHistory" class="secondary" type="button">Listening History</button><button id="settingsClipEditor" class="secondary" type="button" ${track ? "" : "disabled"}>Clip Editor</button></div></section>
      <section class="settings-card"><span class="settings-card-icon" aria-hidden="true">♪</span><div><h2>Local storage</h2><p>${tracksForActiveProfile(state).length} songs on this profile</p><small>Manage imports, downloads, and local files.</small></div><button id="settingsStorage" class="secondary" type="button">Manage storage</button></section>
      <section class="settings-card"><span class="settings-card-icon" aria-hidden="true">↻</span><div><h2>Updates</h2><p id="settingsUpdateStatus">${escapeHTML($("#updateStatus").textContent || "Automatic in-app updates")}</p><small>Installed builds update through the GitHub release feed.</small></div><button id="settingsCheckUpdates" class="secondary" type="button">Check now</button></section>
    </div>
  </div>`;
  $("#settingsServer").onclick = openServerSettings;
  $("#settingsHistory").onclick = openListeningHistory;
  $("#settingsClipEditor").onclick = openClipEditor;
  $("#settingsStorage").onclick = () => navigate("storage");
  $("#settingsCheckUpdates").onclick = checkForUpdates;
}

function render() {
  if (section === "library") renderLibrary();
  else if (section === "playlists") renderPlaylists();
  else if (section === "storage") renderStorage();
  else if (section === "server") renderServer();
  else renderSettings();
  renderSidebar();
  renderQueue();
  $("#navBack").disabled = navigationIndex === 0;
  $("#navForward").disabled = navigationIndex + 1 >= navigationHistory.length;
}

function bindTrackRows(playbackTracks = playlistTracks()) {
  const trackTable = document.querySelector(".track-table");
  if (trackTable) {
    trackTable.ondragover = (event) => {
      if (!draggingPlaylistTrackID) return;
      event.preventDefault();
      if (event.dataTransfer) event.dataTransfer.dropEffect = "move";
    };
    trackTable.ondrop = async (event) => {
      if (!draggingPlaylistTrackID || !draggingPlaylistTargetID) return;
      event.preventDefault();
      const sourceID = draggingPlaylistTrackID;
      const targetID = draggingPlaylistTargetID;
      const insertAfter = draggingPlaylistInsertAfter;
      clearPlaylistDragFloatingRow();
      draggingPlaylistTrackID = null;
      draggingPlaylistTargetID = null;
      draggingPlaylistInsertAfter = false;
      clearPlaylistDragPreview();
      const playlist = state.playlists.find((item) => item.id === selectedPlaylistID && !item.isSystem);
      if (!playlist || sourceID === targetID) return;
      const sourceIndex = playlist.trackIDs.indexOf(sourceID);
      if (sourceIndex < 0) return;
      playlist.trackIDs.splice(sourceIndex, 1);
      const destinationIndex = playlist.trackIDs.indexOf(targetID);
      if (destinationIndex < 0) {
        playlist.trackIDs.splice(sourceIndex, 0, sourceID);
        return;
      }
      playlist.trackIDs.splice(destinationIndex + (insertAfter ? 1 : 0), 0, sourceID);
      updatePlaylistRemoteSongIDs(state, playlist);
      markPlaylistDirty(playlist);
      if (activePlaybackPlaylistID === playlist.id) setPlaybackContext(tracksForPlaylist(state, playlist.id), playlist.id);
      await persist();
      schedulePlaylistSync();
      renderLibrary();
    };
  }
  document.querySelectorAll("[data-track]").forEach((row) => {
    row.onclick = (event) => {
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
      const [trackID] = playlist.trackIDs.splice(from, 1);
      playlist.trackIDs.splice(to, 0, trackID);
      updatePlaylistRemoteSongIDs(state, playlist);
      markPlaylistDirty(playlist);
      if (activePlaybackPlaylistID === playlist.id) setPlaybackContext(tracksForPlaylist(state, playlist.id), playlist.id);
      await persist();
      schedulePlaylistSync();
      renderLibrary();
      document.querySelector(`[data-track="${CSS.escape(trackID)}"]`)?.focus();
    };
    if (row.dataset.playlistDraggable === "true") {
      row.ondragstart = (event) => {
        draggingPlaylistTrackID = row.dataset.track;
        draggingPlaylistTargetID = null;
        draggingPlaylistInsertAfter = false;
        clearPlaylistDragPreview();
        clearPlaylistDragFloatingRow();
        row.classList.add("dragging");
        const floatingRow = row.cloneNode(true);
        floatingRow.classList.remove("playlist-draggable", "dragging", "drag-preview-up", "drag-preview-down");
        floatingRow.classList.add("playlist-drag-floating");
        floatingRow.removeAttribute("draggable");
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
        if (event.dataTransfer) {
          event.dataTransfer.effectAllowed = "move";
          event.dataTransfer.setData("text/plain", row.dataset.track);
        }
      };
      row.ondragover = (event) => {
        if (!draggingPlaylistTrackID || draggingPlaylistTrackID === row.dataset.track) return;
        event.preventDefault();
        if (event.dataTransfer) event.dataTransfer.dropEffect = "move";
        const insertBefore = event.clientY < row.getBoundingClientRect().top + row.offsetHeight / 2;
        const previewKey = `${row.dataset.track}:${insertBefore ? "before" : "after"}`;
        draggingPlaylistTargetID = row.dataset.track;
        draggingPlaylistInsertAfter = !insertBefore;
        if (previewKey === playlistDragPreviewKey) return;
        clearPlaylistDragPreview();
        playlistDragPreviewKey = previewKey;
        const rows = [...document.querySelectorAll("[data-playlist-draggable]")];
        const sourceIndex = rows.findIndex((item) => item.dataset.track === draggingPlaylistTrackID);
        const targetIndex = rows.indexOf(row);
        if (sourceIndex < 0 || targetIndex < 0) return;
        const destinationIndex = targetIndex + (draggingPlaylistInsertAfter ? 1 : 0) - (sourceIndex < targetIndex ? 1 : 0);
        const endIndex = sourceIndex < targetIndex ? targetIndex - (draggingPlaylistInsertAfter ? 0 : 1) : sourceIndex - 1;
        const startIndex = sourceIndex < targetIndex ? sourceIndex + 1 : targetIndex + (draggingPlaylistInsertAfter ? 1 : 0);
        const previewClass = sourceIndex < targetIndex ? "drag-preview-up" : "drag-preview-down";
        const sourceRow = rows[sourceIndex];
        const adjacentRow = rows[sourceIndex + 1] || rows[sourceIndex - 1];
        const rowPitch = adjacentRow ? Math.abs(adjacentRow.offsetTop - sourceRow.offsetTop) : sourceRow.offsetHeight;
        const offset = `${rowPitch}px`;
        const destinationTop = rows[destinationIndex]?.offsetTop ?? sourceRow.offsetTop;
        playlistDragFloatingRow?.style.setProperty("--playlist-drag-source-offset", `${destinationTop - sourceRow.offsetTop}px`);
        for (let index = startIndex; index <= endIndex; index += 1) {
          rows[index].classList.add(previewClass);
          rows[index].style.setProperty("--playlist-drag-offset", offset);
        }
      };
      row.ondragend = () => {
        draggingPlaylistTrackID = null;
        draggingPlaylistTargetID = null;
        draggingPlaylistInsertAfter = false;
        clearPlaylistDragFloatingRow();
        clearPlaylistDragPreview();
      };
    }
  });
  document.querySelectorAll("[data-favorite]").forEach((button) => button.onclick = (event) => { event.stopPropagation(); toggleFavorite(button.dataset.favorite); });
}

let activeContextMenuReturnFocus = null;
let activeContextMenuPosition = { x: 8, y: 8 };

function closeTrackContextMenu({ restoreFocus = false } = {}) {
  const menu = $("#trackContextMenu");
  if (!menu) return;
  menu.hidden = true;
  menu.innerHTML = "";
  menu.onkeydown = null;
  if (restoreFocus) activeContextMenuReturnFocus?.focus?.();
  activeContextMenuReturnFocus = null;
}

function beginContextMenu(event) {
  event.preventDefault();
  event.stopPropagation();
  closeTrackContextMenu();
  const anchor = event.currentTarget?.getBoundingClientRect?.();
  activeContextMenuReturnFocus = event.currentTarget || null;
  activeContextMenuPosition = {
    x: Number(event.clientX) > 0 ? Number(event.clientX) : (anchor?.left ?? 8) + 24,
    y: Number(event.clientY) > 0 ? Number(event.clientY) : (anchor?.top ?? 8) + 24,
  };
}

function renderContextMenu({ title, subtitle, actions }) {
  const menu = $("#trackContextMenu");
  menu.setAttribute("aria-label", `${title || "Item"} options`);
  const actionMarkup = actions.map((action, index) => {
    if (action.divider) return '<div class="context-divider" role="separator"></div>';
    return `<button class="${action.danger ? "context-danger" : ""}" type="button" role="menuitem" data-context-action="${index}" ${action.disabled ? "disabled" : ""}>
      <span class="context-action-icon" aria-hidden="true">${action.icon || ""}</span>
      <span class="context-action-label">${escapeHTML(action.label)}</span>
      ${action.trailing ? `<span class="context-action-trailing">${escapeHTML(action.trailing)}</span>` : ""}
    </button>`;
  }).join("");
  menu.innerHTML = actionMarkup;
  menu.hidden = false;
  const positionMenu = () => {
    menu.style.left = `${Math.max(8, Math.min(activeContextMenuPosition.x, innerWidth - menu.offsetWidth - 8))}px`;
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
  const playing = track.id === currentID && !audio.paused;
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
  if (options.source === "storage") {
    actions.push(
      { divider: true },
      {
        label: "Remove from device",
        icon: contextTrashIcon,
        danger: true,
        onSelect: async () => {
          if (confirm(`Remove ${track.title} from this device?`)) await deleteStoredTracks([track.id]);
        },
      },
    );
  }
  renderContextMenu({ title: track.title || "Untitled", subtitle: track.artist || "Unknown artist", actions });
}

function openTrackContextMenu(event, trackID, options = {}) {
  const track = state.tracks.find((item) => item.id === trackID && trackBelongsToActiveProfile(state, item));
  if (!track) return;
  beginContextMenu(event);
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
  const localTrack = activeRemoteTrack(song.id);
  const actions = [
    localTrack
      ? { label: "Play on this device", icon: contextPlayIcon, onSelect: () => play(localTrack, tracksForActiveProfile(state), { playlistID: null }) }
      : {
        label: "Download",
        icon: contextDownloadIcon,
        onSelect: async () => {
          selectedRemoteIDs = new Set([song.id]);
          await serverAction("selected");
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
  $("#localImportStage").dataset.stage = value.stage || "idle";
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
  if (localImportResolution?.kind === "youtube_playlist") {
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
    return segments[0] === "track" && /^[a-zA-Z0-9]{22}$/.test(segments[1] || "");
  }
  if (["spotify.link", "www.spotify.link"].includes(hostname)) return segments.length > 0;
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

function clearLocalImportAutoResolve() {
  if (localImportAutoResolveTimer !== null) clearTimeout(localImportAutoResolveTimer);
  localImportAutoResolveTimer = null;
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
  void stopLocalImportPreview({ release: true, resumeMain: true });
  clearLocalImportAutoResolve();
  localImportResolution = null;
  localImportResolvedSourceKey = null;
  localImportBatchContext = null;
  localImportRunning = false;
  localImportArtworkRequest += 1;
  const audioKind = document.querySelector('input[name="localImportMediaKind"][value="audio"]');
  if (audioKind) audioKind.checked = true;
  setLocalImportMediaKindDisabled(false);
  $("#localImportSource").disabled = false;
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
}

function openLocalImport() {
  resetLocalImport();
  $("#localImportSource").value = "";
  $("#localImportDialog").showModal();
  requestAnimationFrame(() => $("#localImportSource").focus());
}

function localImportProviderLabel(candidate) {
  if (candidate.sourceProvider === "youtube_music") return "YouTube Music";
  if (candidate.sourceProvider === "debrid_vault") return "Debrid Vault";
  if (candidate.sourceProvider === "torbox_file") return "TorBox file";
  return "YouTube";
}

function localImportCandidateDetails(candidate) {
  if (localImportResolution?.kind === "youtube_playlist") {
    return [candidate.artist || "Unknown uploader", candidate.durationSeconds ? formatTime(candidate.durationSeconds) : null, "YouTube"];
  }
  if (localImportResolution?.mediaKind === "video") {
    const dimensions = candidate.width && candidate.height ? `${candidate.width}×${candidate.height}` : null;
    return [candidate.qualityLabel || "MP4", dimensions, candidate.fps ? `${candidate.fps} fps` : null, candidate.durationSeconds ? formatTime(candidate.durationSeconds) : null, localImportProviderLabel(candidate)];
  }
  if (candidate.sourceProvider === "debrid_vault") {
    return [candidate.quality, Number.isFinite(candidate.seeders) ? `${candidate.seeders} seeders` : null, candidate.size ? formatBytes(candidate.size) : null, localImportProviderLabel(candidate)];
  }
  if (candidate.sourceProvider === "torbox_file") {
    return [candidate.size ? formatBytes(candidate.size) : null, candidate.contentType, localImportProviderLabel(candidate)];
  }
  return [candidate.artist || "Unknown uploader", candidate.durationSeconds ? formatTime(candidate.durationSeconds) : null, localImportProviderLabel(candidate)];
}

function localImportCandidateCanPreview(candidate) {
  return localImportResolution?.mediaKind === "audio"
    && !candidate?.serverBacked
    && ["youtube", "youtube_music"].includes(candidate?.sourceProvider)
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
    localImportPreviewAudio.volume = normalizedVolume(state.volume);
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

function updateLocalImportSyncForSelection() {
  const selected = document.querySelector('input[name="localImportCandidate"]:checked, input[name="localImportPlaylistItem"]:checked');
  const candidate = localImportResolution?.candidates?.[Number(selected?.value) || 0];
  const serverBacked = Boolean(candidate?.serverBacked);
  const canSync = Boolean(serverAdminToken.trim() && state.serverURL);
  const sync = $("#localImportSync");
  const row = $("#localImportSyncRow");
  sync.checked = true;
  sync.disabled = serverBacked;
  row.classList.toggle("disabled", serverBacked);
  row.title = serverBacked
    ? "This source is already saved to the active server profile."
    : canSync
      ? "Upload a copy to the active server profile after downloading."
      : "Add a server admin key before importing to upload this copy.";
  updateLocalImportConfirmLabel();
}

function localImportUploadConfigurationError(serverBacked = false) {
  if (serverBacked || !$("#localImportSync").checked) return null;
  if (!state.serverURL) {
    return { stage: "syncing", code: "SERVER_URL_REQUIRED", message: "Add a server URL in Music Server settings before uploading." };
  }
  if (!serverAdminToken.trim()) {
    return { stage: "syncing", code: "ADMIN_KEY_REQUIRED", message: "Add a server admin key in Music Server settings before uploading." };
  }
  return null;
}

async function uploadLocalImportTrack(track) {
  if (!track?.filePath) {
    return { ok: false, error: { stage: "syncing", code: "LOCAL_FILE_MISSING", message: "The local song file could not be found for server upload." } };
  }
  const result = await api.uploadLocalImport({
    baseURL: state.serverURL,
    adminToken: serverAdminToken,
    profileID: activeProfileID(),
    filePath: track.filePath,
  });
  if (result?.ok && result.remoteSong && reconcileUploadedTrack(state, track.id, result.remoteSong, {
    serverURL: state.serverURL,
    profileID: activeProfileID(),
  })) {
    playlistMutationGeneration += 1;
    await persist({ refreshSidebar: false });
    schedulePlaylistSync();
  }
  return result;
}

async function refreshServerCatalogAfterLocalImportUpload() {
  if (!state.serverURL || !serverToken.trim()) return;
  try {
    const catalog = await api.fetchCatalog({ baseURL: state.serverURL, token: serverToken, profileID: activeProfileID() });
    serverCatalog = catalog.songs || [];
    hydrateServerCatalogArtwork(serverCatalog);
    serverConnectionText = `Connected • ${catalog.count} song${catalog.count === 1 ? "" : "s"}`;
    if (section === "server") renderServer();
  } catch {
    // The upload already succeeded. A catalog refresh failure should not report
    // that the saved server copy was lost.
  }
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
    const image = new Image();
    image.alt = "";
    image.decoding = "async";
    await new Promise((resolve, reject) => {
      image.onload = resolve;
      image.onerror = reject;
      image.src = artwork;
    });
    if (request !== localImportArtworkRequest) return;
    node.replaceChildren(image);
    node.classList.remove("loading");
    node.classList.add("has-image");
  } catch {
    if (request === localImportArtworkRequest) resetLocalImportArtwork(node, mediaKind);
  }
}

function renderLocalImportResolution() {
  const { track, candidates } = localImportResolution;
  const mediaKind = localImportResolution.mediaKind === "video" ? "video" : "audio";
  const playlist = localImportResolution.kind === "youtube_playlist";
  const showPreviews = mediaKind === "audio" && candidates.length > 1;
  const selectedKind = document.querySelector(`input[name="localImportMediaKind"][value="${mediaKind}"]`);
  if (selectedKind) selectedKind.checked = true;
  $("#localImportResolved").hidden = false;
  $("#localImportSyncRow").hidden = false;
  void renderLocalImportArtwork(track, candidates, mediaKind);
  $("#localImportTrackTitle").textContent = track.title || "Untitled";
  $("#localImportTrackMeta").textContent = playlist
    ? [track.artist, `${candidates.length} available video${candidates.length === 1 ? "" : "s"}`, localImportResolution.playlist?.unavailableCount ? `${localImportResolution.playlist.unavailableCount} unavailable` : null].filter(Boolean).join(" • ")
    : [track.artist, track.album, track.durationSeconds ? formatTime(track.durationSeconds) : null]
    .filter(Boolean).join(" • ");
  $("#localImportCandidateLegend").textContent = playlist ? "Choose videos to download" : "Choose the source to import";
  $("#localImportCandidates").classList.toggle("playlist", playlist);
  $("#localImportCandidates").innerHTML = candidates.map((candidate, index) => `<label class="local-import-candidate${playlist ? " playlist-item" : ""}">
    <input type="${playlist ? "checkbox" : "radio"}" name="${playlist ? "localImportPlaylistItem" : "localImportCandidate"}" value="${index}" ${playlist || index === 0 ? "checked" : ""}>
    <span><strong>${escapeHTML(candidate.title || "Untitled source")}</strong><small>${escapeHTML(localImportCandidateDetails(candidate).filter(Boolean).join(" • "))}</small></span>
    <span class="local-import-confidence">${playlist ? candidate.playlistIndex || index + 1 : escapeHTML(candidate.quality || candidate.confidence || "file")}</span>
    ${showPreviews ? `<button class="local-import-preview-button" type="button" data-local-import-preview="${index}" aria-label="Preview ${escapeHTML(candidate.title || "source")}" aria-pressed="false" title="${localImportCandidateCanPreview(candidate) ? "Preview source" : "Preview unavailable for this source"}" ${localImportCandidateCanPreview(candidate) ? "" : "disabled"}><svg class="preview-play-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5v14l11-7z"/></svg><svg class="preview-pause-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M8 6v12M16 6v12"/></svg></button>` : ""}
  </label>`).join("");
  document.querySelectorAll('input[name="localImportCandidate"], input[name="localImportPlaylistItem"]').forEach((input) => input.onchange = updateLocalImportSyncForSelection);
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
  $("#cancelLocalImport").hidden = true;
  setLocalImportStage({ stage: "awaiting_selection" });
}

async function resolveLinkImport() {
  if (localImportRunning) return;
  clearLocalImportAutoResolve();
  const source = $("#localImportSource").value.trim();
  if (!source) {
    showLocalImportError({ stage: "resolving_metadata", message: "Paste a Spotify track or YouTube video URL first." });
    return;
  }
  await stopLocalImportPreview({ release: true, resumeMain: true });
  localImportRunning = true;
  const mediaKind = selectedLocalImportMediaKind();
  const sourceKey = `${mediaKind}:${source}`;
  localImportResolution = null;
  localImportResolvedSourceKey = null;
  $("#localImportError").hidden = true;
  $("#localImportResolved").hidden = true;
  $("#localImportSyncRow").hidden = true;
  $("#localImportSource").disabled = true;
  $("#localImportSource").setAttribute("aria-busy", "true");
  $("#localImportSource").closest(".local-import-source").classList.add("searching");
  $("#cancelLocalImport").hidden = false;
  $("#chooseLocalFiles").disabled = true;
  setLocalImportMediaKindDisabled(true);
  setLocalImportStage({ stage: "resolving_metadata" });
  try {
    const response = await api.resolveLocalImport({
      source,
      mediaKind,
      baseURL: state.serverURL,
      adminToken: serverAdminToken,
      profileID: activeProfileID(),
    });
    if (!response?.ok) throw response?.error || { stage: "resolving_metadata", message: "The source could not be resolved." };
    localImportResolution = response.result;
    localImportResolvedSourceKey = sourceKey;
    renderLocalImportResolution();
  } catch (error) {
    showLocalImportError(error);
  } finally {
    localImportRunning = false;
    $("#localImportSource").disabled = false;
    $("#localImportSource").removeAttribute("aria-busy");
    $("#localImportSource").closest(".local-import-source").classList.remove("searching");
    $("#chooseLocalFiles").disabled = false;
    setLocalImportMediaKindDisabled(false);
    if (!localImportResolution) $("#cancelLocalImport").hidden = true;
  }
}

async function confirmYouTubePlaylistImport() {
  const selected = [...document.querySelectorAll('input[name="localImportPlaylistItem"]:checked')]
    .map((input) => localImportResolution.candidates[Number(input.value)])
    .filter(Boolean);
  const mediaKind = localImportResolution.mediaKind === "video" ? "video" : "audio";
  if (!selected.length) {
    showLocalImportError({ stage: "awaiting_selection", message: `Choose at least one playlist ${mediaKind === "video" ? "video" : "song"} to download.` });
    return;
  }
  const uploadConfigurationError = localImportUploadConfigurationError(false);
  if (uploadConfigurationError) {
    showLocalImportError(uploadConfigurationError);
    return;
  }
  const playlistTitle = localImportResolution.playlist?.title || localImportResolution.track.title || "YouTube Playlist";
  const uploadRequested = $("#localImportSync").checked;
  await stopLocalImportPreview({ release: true, resumeMain: true });
  localImportRunning = true;
  $("#localImportError").hidden = true;
  $("#confirmLocalImport").disabled = true;
  $("#localImportSource").disabled = true;
  $("#chooseLocalFiles").disabled = true;
  setLocalImportMediaKindDisabled(true);
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
  let duplicates = 0;
  let uploadedCount = 0;
  let cancelled = false;
  const failures = [];
  const uploadFailures = [];
  try {
    for (let index = 0; index < selected.length; index += 1) {
      if (serverTransferCancelRequested) { cancelled = true; break; }
      const candidate = selected[index];
      localImportBatchContext = { index, total: selected.length, title: candidate.title || `Playlist item ${index + 1}` };
      updateLocalImportTransfer({ stage: "inspecting_source" });
      const response = await api.startLocalImport({
        sourceURL: candidate.sourceURL,
        mediaKind,
        metadata: {
          title: candidate.title,
          artist: candidate.artist || "Unknown uploader",
          album: playlistTitle,
          durationSeconds: candidate.durationSeconds,
          artworkURL: candidate.thumbnailURL || localImportResolution.playlist?.artworkURL,
          sourceURL: candidate.sourceURL,
        },
        existing,
      });
      if (!response?.ok) {
        if (response?.error?.code === "CANCELLED") { cancelled = true; break; }
        failures.push({ title: candidate.title, message: response?.error?.message || "Download failed." });
        continue;
      }
      if (response.result.kind === "duplicate") {
        duplicates += 1;
        const duplicate = state.tracks.find((track) => track.id === response.result.trackID) || null;
        if (uploadRequested && duplicate?.filePath) {
          const uploaded = await uploadLocalImportTrack(duplicate);
          if (!uploaded?.ok) uploadFailures.push({
            title: candidate.title,
            message: uploaded?.error?.message || "The local file was found, but the server upload failed.",
          });
          else uploadedCount += 1;
        }
        continue;
      }
      const importedTrack = response.result.track;
      state.tracks.push(importedTrack);
      created.push(importedTrack);
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
      if (uploadRequested && importedTrack.filePath) {
        const uploaded = await uploadLocalImportTrack(importedTrack);
        if (!uploaded?.ok) uploadFailures.push({
          title: candidate.title,
          message: uploaded?.error?.message || "Saved locally, but the server upload failed.",
        });
        else uploadedCount += 1;
      }
    }
    if (uploadedCount) await refreshServerCatalogAfterLocalImportUpload();
    if (created.length) {
      render();
      updateChrome();
    }
    const completed = created.length + duplicates;
    if (cancelled) {
      showNotice(`Playlist download cancelled after ${completed} of ${selected.length} ${mediaKind === "video" ? "videos" : "songs"}.`, "status");
      setLocalImportStage({ stage: "cancelled" });
    } else if (failures.length) {
      showNotice(`Downloaded ${created.length} of ${selected.length} playlist ${mediaKind === "video" ? "videos" : "songs"}; ${failures.length} item${failures.length === 1 ? "" : "s"} could not be completed.`);
      setLocalImportStage({ stage: "failed" });
    } else {
      const duplicateText = duplicates ? ` ${duplicates} already on this device.` : "";
      const uploadedText = uploadedCount ? ` Uploaded ${uploadedCount} to ${activeProfile().name || "the active server profile"}.` : "";
      const uploadText = uploadFailures.length ? ` ${uploadFailures.length} server upload${uploadFailures.length === 1 ? "" : "s"} failed; the local files were kept.` : "";
      showNotice(`Downloaded ${created.length} playlist ${mediaKind === "video" ? "video" : "song"}${created.length === 1 ? "" : "s"}.${duplicateText}${uploadedText}${uploadText}`, uploadFailures.length ? "error" : "status");
      setLocalImportStage({ stage: "complete" });
    }
  } catch (error) {
    showLocalImportError(error);
    setLocalImportStage({ stage: "failed" });
  } finally {
    localImportBatchContext = null;
    localImportRunning = false;
    $("#confirmLocalImport").disabled = false;
    $("#localImportSource").disabled = false;
    $("#chooseLocalFiles").disabled = false;
    setLocalImportMediaKindDisabled(false);
    $("#cancelLocalImport").hidden = true;
    hideServerTransfer("local-import");
    serverTransferCancelRequested = false;
  }
}

async function confirmLinkImport() {
  if (localImportRunning || !localImportResolution) return;
  if (localImportResolution.kind === "youtube_playlist") {
    await confirmYouTubePlaylistImport();
    return;
  }
  const selected = document.querySelector('input[name="localImportCandidate"]:checked');
  const candidate = localImportResolution.candidates[Number(selected?.value) || 0];
  const mediaKind = localImportResolution.mediaKind === "video" ? "video" : "audio";
  if (!candidate) {
    showLocalImportError({ stage: "awaiting_selection", message: `Choose one ${mediaKind} source to import.` });
    return;
  }
  const uploadConfigurationError = localImportUploadConfigurationError(Boolean(candidate.serverBacked));
  if (uploadConfigurationError) {
    showLocalImportError(uploadConfigurationError);
    return;
  }
  await stopLocalImportPreview({ release: true, resumeMain: true });
  localImportRunning = true;
  $("#localImportError").hidden = true;
  $("#confirmLocalImport").disabled = true;
  $("#localImportSource").disabled = true;
  $("#chooseLocalFiles").disabled = true;
  setLocalImportMediaKindDisabled(true);
  $("#cancelLocalImport").hidden = false;
  setLocalImportStage({ stage: "inspecting_source", selected: candidate });
  serverTransferCancelRequested = false;
  updateLocalImportTransfer({ stage: "inspecting_source" });
  localImportKeepStateOnClose = true;
  $("#localImportDialog").close();
  try {
    const metadata = {
      title: localImportResolution.track.title,
      artist: localImportResolution.track.artist,
      album: localImportResolution.track.album,
      durationSeconds: localImportResolution.track.durationSeconds,
      artworkURL: localImportResolution.track.artworkURL || candidate.thumbnailURL,
      sourceURL: localImportResolution.track.sourceURL,
    };
    const existing = state.tracks.map((track) => ({
      id: track.id,
      title: track.title,
      filePath: track.filePath,
      sourceSha256: track.sourceSha256 || null,
      contentSha256: track.contentSha256 || null,
    }));
    const response = candidate.serverBacked ? await api.startExternalImport({
      baseURL: state.serverURL,
      adminToken: serverAdminToken,
      profileID: activeProfileID(),
      sourceURL: candidate.sourceURL,
      resumeSelection: candidate.sourceProvider === "torbox_file",
      fileID: candidate.fileID,
      metadata,
      existing,
    }) : await api.startLocalImport({
      sourceURL: candidate.sourceURL,
      mediaKind,
      metadata,
      existing,
    });
    if (!response?.ok) throw response?.error || { stage: "saving_local", message: "The local song could not be saved." };
    if (response.result.kind === "selection_required") {
      localImportResolution.candidates = response.result.files.map((file) => ({
        title: file.name,
        artist: "",
        album: localImportResolution.track.album,
        durationSeconds: null,
        thumbnailURL: localImportResolution.track.artworkURL,
        sourceProvider: "torbox_file",
        sourceKind: "server_file",
        sourceURL: null,
        fileID: file.id,
        size: file.size,
        contentType: file.contentType,
        confidence: "file",
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
        ? `Imported ${importedTrack.title} on this device and ${activeProfile().name || "the active server profile"}.`
        : `${mediaKind === "video" ? "Downloaded" : "Imported"} ${importedTrack.title} on this device.`, "status");
    }

    if (!response.result.serverBacked && $("#localImportSync").checked && importedTrack?.filePath) {
      setLocalImportStage({ stage: "syncing", profileID: activeProfileID() });
      const uploaded = await uploadLocalImportTrack(importedTrack);
      if (!uploaded?.ok) {
        showLocalImportError(uploaded?.error || { stage: "syncing", message: "The song was saved locally, but its optional profile upload failed." });
        return;
      }
      await refreshServerCatalogAfterLocalImportUpload();
      showNotice(`Uploaded ${importedTrack.title} to ${activeProfile().name || "the active server profile"}.`, "status");
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
    localImportRunning = false;
    $("#confirmLocalImport").disabled = false;
    $("#localImportSource").disabled = false;
    $("#chooseLocalFiles").disabled = false;
    setLocalImportMediaKindDisabled(false);
    if ($("#localImportStage").dataset.stage !== "downloading") $("#cancelLocalImport").hidden = true;
    hideServerTransfer("local-import");
    serverTransferCancelRequested = false;
  }
}

async function cancelLinkImport() {
  if (!localImportRunning) return;
  $("#cancelLocalImport").disabled = true;
  try { await api.cancelLocalImport(); }
  finally {
    $("#cancelLocalImport").disabled = false;
    setLocalImportStage({ stage: "cancelled" });
  }
}

async function closeLocalImport() {
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
  serverToken = $("#serverToken")?.value || serverToken;
  const status = $("#serverStatus");
  await saveServerForm();
  const context = currentProfileContext();
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
      if (!profileContextIsCurrent(context)) return;
      serverConnectionText = `Connected • ${catalog.count} song${catalog.count === 1 ? "" : "s"}`;
    }
    if (catalog) {
      serverCatalog = catalog.songs || [];
      serverConnected = true;
      hydrateServerCatalogArtwork(serverCatalog);
    }
    await persist();
    renderSidebar();
    if (!transferCancelled) await syncPlaylistsNow({ automatic: true });
  } catch (error) {
    if (!profileContextIsCurrent(context)) return;
    serverConnectionText = serverTransferCancelRequested ? "Download cancelled" : friendlyIPCError(error, "Connection failed");
    serverConnected = false;
    serverCatalog = [];
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
  await saveServerForm();
  const context = currentProfileContext();
  const status = $("#serverStatus");
  serverTransferCancelRequested = false;
  updateServerTransfer({ direction: "upload", currentFile: "Choose songs to upload…", completed: 0, total: 1 });
  try {
    const result = await api.uploadServer({ baseURL: context.serverURL, adminToken: serverAdminToken, profileID: context.profileID });
    if (!profileContextIsCurrent(context)) return;
    const cancelled = Boolean(result.cancelled || serverTransferCancelRequested);
    serverConnectionText = cancelled
      ? `Upload cancelled${result.uploaded ? ` • ${result.uploaded} completed` : ""}`
      : `Uploaded ${result.uploaded} song${result.uploaded === 1 ? "" : "s"}`;
    if (status) status.textContent = serverConnectionText;
    if (cancelled) {
      const catalog = await api.fetchCatalog({ baseURL: context.serverURL, token: context.token, profileID: context.profileID });
      if (!profileContextIsCurrent(context)) return;
      serverCatalog = catalog.songs || [];
      serverConnected = true;
      hydrateServerCatalogArtwork(serverCatalog);
      if (section === "server") renderServer();
    } else {
      await serverAction("catalog");
    }
  } catch (error) {
    if (!profileContextIsCurrent(context)) return;
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
    audio.currentTime = range.startSeconds;
    state.position = range.startSeconds;
    void requestPlayback();
  } else {
    move(1);
  }
  queueMicrotask(() => { clipBoundaryTrackID = null; });
  return true;
}

function play(track, queue = null, options = {}) {
  if (!track) return;
  const { recordHistory = true, playlistID = activePlaybackPlaylistID } = options;
  if (Array.isArray(queue) && queue.length) setPlaybackContext(queue, playlistID);
  else if (!activePlaybackQueueIDs.includes(track.id)) setPlaybackContext(tracksForActiveProfile(state), null);
  if (recordHistory && currentID && currentID !== track.id) history.push(currentID);
  if (activeListeningEntryID) {
    updateListeningSession();
    persistInBackground();
    scheduleListeningHistorySync();
  }
  activeListeningEntryID = null;
  lastListeningPosition = 0;
  lastPersistedListeningSeconds = 0;
  currentID = track.id;
  state.currentTrackID = currentID;
  const range = playbackRangeForTrack(state, track);
  state.position = range?.startSeconds ?? 0;
  pendingRestorePosition = state.position;
  audio.src = track.fileUrl;
  audio.volume = normalizedVolume(state.volume);
  audio.playbackRate = Number($("#speed").value) || 1;
  void requestPlayback();
  persistInBackground(); updateChrome(); render();
}

function toggle() {
  const track = currentTrack();
  if (!track) {
    const firstTrack = tracksForActiveProfile(state)[0];
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
  const tracks = activePlaybackTracks();
  const index = nextIndex(tracks, currentID, direction, shuffle);
  if (index >= 0) play(tracks[index], null, { recordHistory });
}

function previous() {
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
  $("#sidebarPlaylists").innerHTML = state.playlists.map((playlist) => `<button data-side-playlist="${playlist.id}" aria-keyshortcuts="Shift+F10"><span>${playlist.isSystem ? "♥" : "♪"}</span><div><strong>${escapeHTML(playlist.name)}</strong><small>${playlist.trackIDs.length} tracks</small></div></button>`).join("");
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
  const queue = index < 0 ? tracks : [...tracks.slice(index + 1), ...tracks.slice(0, index)];
  $("#queue").innerHTML = queue.slice(0, 12).map((track) => `<button data-queue="${track.id}">${artwork(track)}<span><strong>${escapeHTML(track.title)}</strong><small>${escapeHTML(track.artist)}</small></span><time>${formatTime(track.duration)}</time></button>`).join("") || `<div class="empty"><span>Queue is empty</span></div>`;
  document.querySelectorAll("[data-queue]").forEach((button) => button.onclick = () => play(state.tracks.find((track) => track.id === button.dataset.queue && trackBelongsToActiveProfile(state, track))));
}

function fullPlayerQueueTracks() {
  const tracks = activePlaybackTracks();
  const index = tracks.findIndex((track) => track.id === currentID);
  return index < 0 ? tracks : [...tracks.slice(index + 1), ...tracks.slice(0, index)];
}

function fullPlayerHistoryTracks() {
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
  $("#fullPlayerQueue").innerHTML = queue.length ? queue.map((track) => `<button class="full-player-queue-item" type="button" data-full-player-queue="${escapeHTML(track.id)}" aria-label="Play ${escapeHTML(track.title || "Untitled")} by ${escapeHTML(track.artist || "Unknown Artist")}">
    ${artwork(track)}<span><strong>${escapeHTML(track.title || "Untitled")}</strong><small>${escapeHTML(track.artist || "Unknown Artist")}</small></span><time>${formatTime(track.duration)}</time>
  </button>`).join("") : `<div class="full-player-queue-empty"><span>${fullPlayerQueueTab === "history" ? "Nothing played yet." : "Nothing else is queued."}</span></div>`;
  document.querySelectorAll("[data-full-player-queue]").forEach((button) => {
    button.onclick = () => play(state.tracks.find((track) => track.id === button.dataset.fullPlayerQueue && trackBelongsToActiveProfile(state, track)));
  });
}

function updateFullPlayerProgress() {
  const elapsed = Number(audio.currentTime) || 0;
  const duration = Number(audio.duration) || Number(currentTrack()?.duration) || 0;
  const seek = $("#fullPlayerSeek");
  $("#fullPlayerElapsed").textContent = formatTime(elapsed);
  $("#fullPlayerDuration").textContent = formatTime(duration);
  seek.value = duration ? String(Math.round(elapsed / duration * 1000)) : "0";
  seek.setAttribute("aria-valuetext", `${formatTime(elapsed)} of ${formatTime(duration)}`);
  paintRange(seek);
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
  $("#fullPlayerTitle").textContent = track.title || "Untitled";
  $("#fullPlayerArtist").textContent = track.artist || "Unknown Artist";
  const releaseYear = Number(track.year || track.releaseYear) || null;
  $("#fullPlayerAlbum").textContent = [displayAlbum(track), releaseYear].filter(Boolean).join(" • ");
  const artworkNode = $("#fullPlayerArtwork");
  artworkNode.innerHTML = track.artwork ? `<img src="${escapeHTML(track.artwork)}" alt="">` : '<span aria-hidden="true">♪</span>';
  artworkNode.setAttribute("aria-label", `Artwork for ${track.title || "current song"}`);
  const backdropNode = $("#fullPlayerBackdrop");
  backdropNode.innerHTML = track.artwork ? `<img src="${escapeHTML(track.artwork)}" alt="">` : "";
  const favorite = $("#fullPlayerFavorite");
  favorite.classList.toggle("active", liked);
  favorite.setAttribute("aria-pressed", String(liked));
  favorite.setAttribute("aria-label", liked ? "Remove current song from Liked Songs" : "Add current song to Liked Songs");
  favorite.title = liked ? "Remove from Liked Songs" : "Add to Liked Songs";
  $("#fullPlayerShuffle").classList.toggle("active", shuffle);
  $("#fullPlayerShuffle").setAttribute("aria-pressed", String(shuffle));
  $("#fullPlayerRepeat").classList.toggle("active", repeat);
  $("#fullPlayerRepeat").setAttribute("aria-pressed", String(repeat));
  setCustomSelectValue($("#fullPlayerSpeed"), audio.playbackRate || state.playbackRate || 1);
  $("#fullPlayerVolume").value = String(audio.volume);
  $("#fullPlayerVolume").setAttribute("aria-valuetext", `${Math.round(audio.volume * 100)} percent`);
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
  requestAnimationFrame(() => $("#closeNowPlaying").focus());
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
  const playing = track && !audio.paused;
  const liked = Boolean(track && state.favorites.includes(track.id));
  $("#bottomTitle").textContent = track?.title || "Nothing playing";
  $("#bottomMeta").textContent = track ? `${track.artist} / ${playing ? "Now playing" : "Paused"}` : "Local library";
  $(".mini-art").innerHTML = track?.artwork ? `<img src="${escapeHTML(track.artwork)}" alt="">` : "♪";
  document.querySelectorAll("[data-action=toggle]").forEach((button) => {
    button.innerHTML = playing ? playbackPauseIcon : playbackPlayIcon;
    button.setAttribute("aria-label", playing ? "Pause" : "Play");
    button.title = playing ? "Pause" : "Play";
  });
  const collectionButton = $("#playCollection");
  const collectionPlaying = playing && isCurrentCollectionPlayback();
  if (collectionButton) collectionButton.innerHTML = `<span class="button-icon">${collectionPlaying ? playbackPauseIcon : playbackPlayIcon}</span><span>${collectionPlaying ? "Pause" : "Play"}</span>`;
  $("#favoriteCurrent").textContent = liked ? "♥" : "♡";
  $("#favoriteCurrent").disabled = !track;
  $("#favoriteCurrent").setAttribute("aria-pressed", String(liked));
  $("#favoriteCurrent").setAttribute("aria-label", liked ? "Remove current song from Liked Songs" : "Add current song to Liked Songs");
  $("#favoriteCurrent").title = liked ? "Remove from Liked Songs" : "Add to Liked Songs";
  $("#shuffle").classList.toggle("active", shuffle);
  $("#repeat").classList.toggle("active", repeat);
  $("#shuffle").setAttribute("aria-pressed", String(shuffle));
  $("#repeat").setAttribute("aria-pressed", String(repeat));
  $("#heroShuffle")?.setAttribute("aria-pressed", String(shuffle));
  renderFullPlayer();
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
$("#openNowPlaying").onclick = openNowPlaying;
$("#closeNowPlaying").onclick = closeNowPlaying;
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
$("#fullPlayerFavorite").onclick = () => currentID && toggleFavorite(currentID);
$("#fullPlayerMore").onclick = (event) => currentID && openTrackContextMenu(event, currentID, { playbackTracks: activePlaybackTracks(), playlistID: activePlaybackPlaylistID });
$("#fullPlayerQueueToggle").onclick = () => setFullPlayerQueueVisible($("#fullPlayerQueuePanel").hidden);
$("#closeFullPlayerQueue").onclick = () => setFullPlayerQueueVisible(false);
document.querySelectorAll("[data-full-player-queue-tab]").forEach((button) => {
  button.onclick = () => {
    fullPlayerQueueTab = button.dataset.fullPlayerQueueTab;
    renderFullPlayerQueue();
  };
});
$("#fullPlayerShuffle").onclick = () => {
  shuffle = !shuffle;
  state.shuffle = shuffle;
  persistInBackground();
  updateChrome();
};
$("#fullPlayerRepeat").onclick = () => {
  repeat = !repeat;
  state.repeat = repeat;
  persistInBackground();
  updateChrome();
};
$("#newPlaylist").onclick = () => newPlaylist();
$("#profileButton").onclick = toggleProfileMenu;
$("#profileSwitch").onclick = openProfileSwitcher;
$("#profileHistory").onclick = openListeningHistory;
$("#profileClipEditor").onclick = openClipEditor;
$("#profileSettings").onclick = () => {
  closeProfileMenu();
  navigate("settings");
};
$("#dismissServerTransfer").onclick = cancelServerTransfer;
$("#dismissAppNotice").onclick = dismissNotice;
$("#cancelPlaylist").onclick = () => { pendingPlaylistTrackID = null; $("#playlistDialog").close(); };
$("#playlistName").oninput = () => { $("#createPlaylist").disabled = !$("#playlistName").value.trim(); };
$("#closeAddSongs").onclick = () => $("#addSongsDialog").close();
$("#closeClipEditor").onclick = async () => { await stopClipRangePreview(); $("#clipEditorDialog").close(); };
$("#previewClipRange").onclick = toggleClipRangePreview;
$("#saveClipRange").onclick = saveClipRange;
$("#clearClipRange").onclick = clearClipRange;
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
clipEditorPreviewAudio.onplay = syncClipRangePreviewButton;
clipEditorPreviewAudio.onpause = syncClipRangePreviewButton;
clipEditorPreviewAudio.onended = () => { void stopClipRangePreview(); };
clipEditorPreviewAudio.ontimeupdate = () => {
  if (!clipEditorPreviewEndSeconds || clipEditorPreviewAudio.currentTime + 0.02 < clipEditorPreviewEndSeconds) return;
  void stopClipRangePreview();
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
$("#localImportSource").oninput = () => {
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
  scheduleLocalImportResolution();
};
document.querySelectorAll('input[name="localImportMediaKind"]').forEach((input) => {
  input.onchange = () => {
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
$("#cancelProfileSwitch").onclick = () => $("#profileSwitchDialog").close();
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
$("#cancelServerSettings").onclick = () => $("#serverSettingsDialog").close();
$("#newSyncProfile").onclick = async () => {
  const name = prompt("Name this sync profile:");
  if (!name?.trim()) return;
  try {
    const profile = await api.createProfile({
      baseURL: $("#serverURL")?.value.trim() || state.serverURL,
      token: $("#serverToken")?.value || serverToken,
      name: name.trim(),
    });
    state.syncProfiles = [...state.syncProfiles, profile];
    renderProfileOptions(profile.id);
  } catch (error) {
    alert(error.message || "Could not create the sync profile.");
  }
};
$("#serverSettingsForm").onsubmit = async (event) => {
  event.preventDefault();
  serverAutoAttempted = true;
  await saveServerForm();
  $("#serverSettingsDialog").close();
  if (section === "server") await serverAction("catalog");
};

async function finishProfileSelection(profile) {
  renderProfileOptions(profile.id);
  const previousProfileID = activeProfileID();
  await activateProfile(profile.id);
  await persist();
  updateProfileControl();
  $("#profileSwitchDialog").close();
  render();
  if (profile.id !== previousProfileID) {
    schedulePlaylistSync();
    scheduleListeningHistorySync();
    await serverAction("catalog");
  }
}

$("#createProfileFromSwitcher").onclick = async () => {
  const name = $("#profileSwitchQuery").value.replace(/\s+/g, " ").trim();
  const status = $("#profileSwitchStatus");
  const create = $("#createProfileFromSwitcher");
  const submit = $("#confirmProfileSwitch");
  if (!name) {
    status.textContent = "Enter a name for the new profile.";
    return;
  }
  const existing = matchingSyncProfile(name);
  if (existing) {
    status.textContent = existing.id === activeProfileID() ? "That is already the current profile." : "That profile already exists. Use Switch instead.";
    updateProfileSwitchActions();
    return;
  }
  if (!state.serverURL || !serverToken) {
    status.textContent = "Connect to the music server in Settings first.";
    return;
  }
  create.disabled = true;
  submit.disabled = true;
  status.textContent = "Creating profile…";
  try {
    const profile = await api.createProfile({
      baseURL: state.serverURL,
      token: serverToken,
      name,
    });
    state.syncProfiles = [...state.syncProfiles.filter((item) => item.id !== profile.id), profile];
    await finishProfileSelection(profile);
    showNotice(`Created and switched to ${profile.name || name}.`, "status");
  } catch (error) {
    status.textContent = error.message || "Could not create the profile.";
  } finally {
    if ($("#profileSwitchDialog").open) updateProfileSwitchActions();
  }
};

$("#profileSwitchForm").onsubmit = async (event) => {
  event.preventDefault();
  const query = $("#profileSwitchQuery").value.trim();
  const status = $("#profileSwitchStatus");
  const submit = $("#confirmProfileSwitch");
  if (!query) {
    status.textContent = "Enter a profile name or ID.";
    return;
  }
  if (!state.serverURL || !serverToken) {
    status.textContent = "Connect to the music server in Settings first.";
    return;
  }
  submit.disabled = true;
  status.textContent = "Checking server profiles…";
  try {
    const response = await api.fetchProfiles({ baseURL: state.serverURL, token: serverToken });
    state.syncProfiles = response.profiles || [];
    const resolution = resolveSyncProfile(state.syncProfiles, query, response.default_profile_id);
    const { profile } = resolution;
    if (!profile) throw new Error(`No server profile matches “${query}”.`);
    await finishProfileSelection(profile);
    if (resolution.fellBackToDefault) {
      showNotice(`Profile “${query}” was not found. Switched to ${profile.name || "Default"}.`, "status");
    }
  } catch (error) {
    status.textContent = error.message || "Could not switch profiles.";
  } finally {
    if ($("#profileSwitchDialog").open) updateProfileSwitchActions();
  }
};
$("#profileSwitchQuery").oninput = () => updateProfileSwitchActions();
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
  const open = sort.classList.toggle("open");
  $("#searchSortButton").setAttribute("aria-expanded", String(open));
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
$("#shuffle").onclick = () => { shuffle = !shuffle; state.shuffle = shuffle; persistInBackground(); updateChrome(); };
$("#repeat").onclick = () => { repeat = !repeat; state.repeat = repeat; persistInBackground(); updateChrome(); };
function paintRange(input) {
  const minimum = Number(input.min) || 0;
  const maximum = Number(input.max) || 100;
  const progress = maximum > minimum ? ((Number(input.value) - minimum) / (maximum - minimum)) * 100 : 0;
  input.style.setProperty("--range-progress", `${Math.max(0, Math.min(100, progress))}%`);
}
$("#volume").oninput = async (event) => {
  audio.volume = normalizedVolume(event.target.value);
  state.volume = audio.volume;
  const percent = Math.round(audio.volume * 100);
  $("#volumeText").textContent = `${percent}%`;
  event.target.setAttribute("aria-valuetext", `${percent} percent`);
  paintRange(event.target);
  $("#fullPlayerVolume").value = String(audio.volume);
  $("#fullPlayerVolume").setAttribute("aria-valuetext", `${percent} percent`);
  paintRange($("#fullPlayerVolume"));
  await persist();
};
$("#fullPlayerVolume").oninput = async (event) => {
  audio.volume = normalizedVolume(event.target.value);
  state.volume = audio.volume;
  const percent = Math.round(audio.volume * 100);
  event.target.setAttribute("aria-valuetext", `${percent} percent`);
  paintRange(event.target);
  $("#volume").value = String(audio.volume);
  $("#volumeText").textContent = `${percent}%`;
  $("#volume").setAttribute("aria-valuetext", `${percent} percent`);
  paintRange($("#volume"));
  await persist();
};
$("#speed").onchange = (event) => {
  audio.playbackRate = Number(event.target.value);
  state.playbackRate = audio.playbackRate;
  setCustomSelectValue($("#fullPlayerSpeed"), audio.playbackRate);
  persistInBackground();
};
$("#fullPlayerSpeed").onchange = (event) => {
  audio.playbackRate = Number(event.target.value);
  state.playbackRate = audio.playbackRate;
  setCustomSelectValue($("#speed"), audio.playbackRate);
  persistInBackground();
};
$("#seek").oninput = (event) => {
  if (audio.duration) audio.currentTime = clippedPlaybackPosition(audio.duration * Number(event.target.value) / 1000);
  event.target.value = audio.duration ? String(Math.round(audio.currentTime / audio.duration * 1000)) : "0";
  event.target.setAttribute("aria-valuetext", `${formatTime(audio.currentTime)} of ${formatTime(audio.duration)}`);
  paintRange(event.target);
};
$("#fullPlayerSeek").oninput = (event) => {
  if (audio.duration) audio.currentTime = clippedPlaybackPosition(audio.duration * Number(event.target.value) / 1000);
  event.target.value = audio.duration ? String(Math.round(audio.currentTime / audio.duration * 1000)) : "0";
  updateFullPlayerProgress();
  $("#seek").value = event.target.value;
  $("#seek").setAttribute("aria-valuetext", `${formatTime(audio.currentTime)} of ${formatTime(audio.duration)}`);
  paintRange($("#seek"));
};
audio.ontimeupdate = () => {
  if (pendingRestorePosition !== null) return;
  if (finishClipPlaybackIfNeeded()) return;
  $("#elapsed").textContent = formatTime(audio.currentTime);
  $("#duration").textContent = formatTime(audio.duration);
  $("#seek").value = audio.duration ? String(Math.round(audio.currentTime / audio.duration * 1000)) : "0";
  $("#seek").setAttribute("aria-valuetext", `${formatTime(audio.currentTime)} of ${formatTime(audio.duration)}`);
  paintRange($("#seek"));
  updateFullPlayerProgress();
  state.position = audio.currentTime;
  updateListeningSession();
  schedulePlaybackProgressSave();
};
audio.onplay = () => { beginListeningSession(); updateChrome(); renderQueue(); };
audio.onpause = () => {
  updateListeningSession();
  scheduleListeningHistorySync();
  updateChrome();
  if (playbackProgressTimer) {
    clearTimeout(playbackProgressTimer);
    playbackProgressTimer = null;
  }
  persistInBackground({ refreshSidebar: false });
};
audio.onended = () => {
  updateListeningSession();
  scheduleListeningHistorySync();
  const range = activeClipRange();
  if (repeat && range) {
    audio.currentTime = range.startSeconds;
    state.position = range.startSeconds;
    void requestPlayback();
  } else if (repeat) play(currentTrack(), null, { recordHistory: false });
  else move(1);
};
audio.onerror = () => {
  updateChrome();
  showNotice("This song could not be played. The file may be missing, inaccessible, or unsupported.");
};
audio.onloadedmetadata = async () => {
  const track = currentTrack();
  if (pendingRestorePosition !== null) {
    if (Number.isFinite(audio.duration) && audio.duration > 0) {
      audio.currentTime = clippedPlaybackPosition(Math.min(pendingRestorePosition, Math.max(0, audio.duration - 0.25)));
      state.position = audio.currentTime;
    }
    pendingRestorePosition = null;
  }
  if (track && audio.duration && track.duration !== audio.duration) {
    track.duration = audio.duration;
    await persist();
    renderQueue();
  }
};

const libraryLoad = await api.loadLibrary();
const loadedState = libraryLoad && Object.hasOwn(libraryLoad, "state") ? libraryLoad.state : libraryLoad;
state = normalizeState(loadedState);
let closeFlushStarted = false;
api.onPrepareToClose(async () => {
  if (closeFlushStarted) return;
  closeFlushStarted = true;
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
({ clientToken: serverToken = "", adminToken: serverAdminToken = "" } = await api.loadServerCredentials());
const localImportCapabilities = await api.localImportCapabilities().catch(() => ({ enabled: false }));
localImportAvailable = Boolean(localImportCapabilities?.enabled);
shuffle = Boolean(state.shuffle); repeat = Boolean(state.repeat);
state.volume = normalizedVolume(state.volume);
$("#volume").value = state.volume;
paintRange($("#volume"));
paintRange($("#seek"));
setCustomSelectValue($("#speed"), state.playbackRate || 1);
setCustomSelectValue($("#fullPlayerSpeed"), state.playbackRate || 1);
$("#volumeText").textContent = `${Math.round(state.volume * 100)}%`;
$("#volume").setAttribute("aria-valuetext", `${Math.round(state.volume * 100)} percent`);
const initialVisibleTracks = tracksForActiveProfile(state);
const restoredCurrentID = state.currentTrackID && initialVisibleTracks.some((track) => track.id === state.currentTrackID) ? state.currentTrackID : null;
currentID = restoredCurrentID || initialVisibleTracks[0]?.id || null;
activePlaybackQueueIDs = state.playbackQueueIDs.length
  ? state.playbackQueueIDs.filter((id) => initialVisibleTracks.some((track) => track.id === id))
  : initialVisibleTracks.map((track) => track.id);
activePlaybackPlaylistID = state.playbackPlaylistID;
if (currentID && !activePlaybackQueueIDs.includes(currentID)) activePlaybackQueueIDs.unshift(currentID);
state.playbackQueueIDs = [...activePlaybackQueueIDs];
if (currentID) {
  const track = currentTrack();
  pendingRestorePosition = restoredCurrentID ? Math.max(0, Number(state.position) || 0) : 0;
  if (!restoredCurrentID) state.position = 0;
  audio.src = track.fileUrl;
  audio.volume = state.volume;
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

api.onUpdateStatus((value) => {
  const install = $("#installUpdate");
  if (!install) return;
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
});
$("#checkForUpdates").onclick = checkForUpdates;
$("#installUpdate").onclick = async () => {
  const install = $("#installUpdate");
  const status = $("#updateStatus");
  install.disabled = true;
  status.textContent = "Restarting to finish the update…";
  try {
    const started = await api.installUpdate();
    if (!started) {
      install.hidden = true;
      status.textContent = "Available in installed builds";
    }
  } catch (error) {
    install.disabled = false;
    status.textContent = error.message || "Could not install the update";
  }
};
render(); updateChrome();
syncPlaylistsNow({ automatic: true });
syncListeningHistoryNow();
setInterval(() => syncPlaylistsNow({ automatic: true }), 60000);
setInterval(() => syncListeningHistoryNow(), 60000);
