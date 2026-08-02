import {
  applyRemotePlaylistDocument,
  createEmptyState,
  filterPlaylists,
  filterTracks,
  formatHistoryWindowLabel,
  formatTime,
  mergeListeningHistory,
  mergePlaylistDocument,
  mergeSyncedTracks,
  nextIndex,
  niceChartMaximum,
  normalizedVolume,
  normalizeState,
  resolveSyncProfile,
  summarizeListeningHistory,
  summarizeListeningStats,
  tracksForPlaylist,
  updatePlaylistRemoteSongIDs,
} from "./core.js";

const api = window.likedSongs;
const audio = document.querySelector("#audio");
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
let navigationHistory = [{ section: "library", playlistID: null }];
let navigationIndex = 0;
let pendingPlaylistTrackID = null;
let addSongsPlaylistID = null;
let libraryQuery = "";
let playlistQuery = "";
let recentlyAddedScrollLeft = 0;
let playlistSyncInFlight = null;
let playlistSyncTimer = null;
let likesMutationGeneration = 0;
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
let serverConnectInFlight = false;
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
const LOCAL_IMPORT_AUTO_RESOLVE_DELAY = 450;
let clipEditorStartSeconds = 0;
let clipEditorEndSeconds = 30;
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
const escapeHTML = (value) => String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" }[character]));
const currentTrack = () => state.tracks.find((track) => track.id === currentID) || null;
const playlistTracks = () => selectedPlaylistID ? tracksForPlaylist(state, selectedPlaylistID) : state.tracks;
const activeProfile = () => state.syncProfiles.find((profile) => profile.id === activeProfileID())
  || state.syncProfiles.find((profile) => profile.id === "default")
  || { id: "default", name: "Default" };

function activePlaybackTracks() {
  return activePlaybackQueueIDs
    .map((id) => state.tracks.find((track) => track.id === id))
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
  $("#appNoticeText").textContent = String(message || "Something went wrong.");
  notice.dataset.kind = kind;
  notice.setAttribute("role", kind === "error" ? "alert" : "status");
  notice.setAttribute("aria-live", kind === "error" ? "assertive" : "polite");
  notice.hidden = false;
}

function friendlyIPCError(error, fallback) {
  const message = String(error?.message || fallback || "Something went wrong.");
  return message.replace(/^Error invoking remote method '[^']+':\s*(?:Error:\s*)?/, "");
}

function dismissNotice() {
  const notice = $("#appNotice");
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
  return state.tracks.find((track) => track.id === $("#clipEditorTrack").value) || null;
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
  if (boundary === "start") clipEditorStartSeconds = Math.min(value, clipEditorEndSeconds - 1);
  else clipEditorEndSeconds = Math.max(clipEditorStartSeconds + 1, value);
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
  if (!track) return;
  const duration = clipEditorDuration(track);
  $("#clipEditorTrackTitle").textContent = track.title || "Unknown title";
  $("#clipEditorTrackMeta").textContent = `${track.artist || "Unknown Artist"} · ${track.album || "Unknown Album"}`;
  $("#clipEditorTrackDuration").textContent = formatTime(duration);
  $("#clipEditorArtwork").innerHTML = track.artwork ? `<img src="${escapeHTML(track.artwork)}" alt="">` : "♪";
  $("#clipEditorWaveBars").innerHTML = clipEditorWaveBars(track);
  if (resetRange) {
    const defaultStart = duration > 60 ? 15 : 0;
    clipEditorStartSeconds = defaultStart;
    clipEditorEndSeconds = Math.min(duration, defaultStart + 45);
  }
  updateClipEditorRange();
}

function openClipEditor() {
  closeProfileMenu();
  const select = $("#clipEditorTrack");
  select.innerHTML = state.tracks.map((track) => `<option value="${escapeHTML(track.id)}">${escapeHTML(track.title)} — ${escapeHTML(track.artist || "Unknown Artist")}</option>`).join("");
  const preferredTrack = state.tracks.find((track) => track.id === currentID) || state.tracks[0];
  if (preferredTrack) select.value = preferredTrack.id;
  renderClipEditorTrack({ resetRange: true });
  $("#clipEditorDialog").showModal();
  requestAnimationFrame(() => (preferredTrack ? select : $("#closeClipEditor")).focus());
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
      return { activity, track, trackID: series.trackID, series };
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
  const songRows = songs.map(({ activity, track, trackID, series }, index) => {
    const title = track?.title || series.title || "Removed song";
    const artist = track?.artist || series.artist || "Unknown artist";
    const album = track?.album || series.album || "Unknown album";
    return `<div class="history-day-song" role="row" data-history-track="${escapeHTML(trackID)}">
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
      <button id="closeHistoryDayDetails" type="button" title="Collapse day details" aria-label="Collapse day details">×</button>
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
  const bottom = 8;
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
    const title = track?.title || song.title || "Removed song";
    const artist = track?.artist || song.artist || "Unknown artist";
    return `<article class="history-ranked-song">
      <span class="history-ranked-position">#${index + 1}</span>
      ${artwork(track)}
      <strong title="${escapeHTML(title)}">${escapeHTML(title)}</strong>
      <small title="${escapeHTML(artist)}">${escapeHTML(artist)}</small>
      <em>${escapeHTML(historyListenedTime(song.seconds))} · ${song.plays.toLocaleString()} ${song.plays === 1 ? "play" : "plays"}</em>
    </article>`;
  }).join("");
  const topSongTitle = topTrack?.title || allTimeStats.songRanking[0]?.title || (allTimeStats.topTrackID ? "Removed song" : "No listening yet");
  const topSongArtist = topTrack?.artist || allTimeStats.songRanking[0]?.artist || (allTimeStats.topTrackID ? "Unknown artist" : "Play a song to build your ranking");
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
}

function openListeningHistory() {
  closeProfileMenu();
  listeningHistoryMode = "overall";
  listeningHistoryWindowOffset = 0;
  listeningHistorySongsExpanded = false;
  ensureListeningHistorySelection();
  renderListeningHistory();
  $("#listeningHistoryDialog").showModal();
  void syncListeningHistoryNow({ force: true }).then(() => {
    if ($("#listeningHistoryDialog").open) renderListeningHistory();
  });
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
    remoteID: track.remoteID || null,
    startedAt: new Date().toISOString(),
    listenedSeconds: 0,
    title: track.title || null,
    artist: track.artist || null,
    album: track.album || null,
    duration: Number.isFinite(Number(track.duration)) ? Number(track.duration) : null,
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
        remoteID: optionalText(track?.remoteID ?? entry.remoteID, 128),
        startedAt: entry.startedAt,
        listenedSeconds,
        title: optionalText(track?.title ?? entry.title, 500),
        artist: optionalText(track?.artist ?? entry.artist, 500),
        album: optionalText(track?.album ?? entry.album, 500),
        duration: Number.isFinite(duration) && duration >= 0 && duration <= 7 * 24 * 60 * 60
          ? duration
          : (Number.isFinite(Number(entry.duration)) ? Number(entry.duration) : null),
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
  if (!serverToken.trim() || !state.serverURL) return;
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
    const pullProfileID = activeProfileID();
    try {
      const result = await api.fetchListeningHistory({
        baseURL: state.serverURL,
        token: serverToken,
        profileID: pullProfileID,
      });
      if (result?.supported !== false) {
        state.listeningHistory = mergeListeningHistory(state, pullProfileID, result?.entries);
        const baseKey = normalizedServerKey(state.serverURL);
        for (const entry of result?.entries || []) {
          const eventID = typeof entry?.id === "string" ? entry.id : "";
          if (!eventID) continue;
          const listenedSeconds = Math.max(0, Number(entry.listenedSeconds ?? entry.listened_seconds) || 0);
          listeningHistorySyncedSeconds.set(
            `${baseKey}#profile=${pullProfileID}#event=${eventID}`,
            listenedSeconds,
          );
        }
        await persist({ refreshSidebar: false });
        if ($("#listeningHistoryDialog").open) renderListeningHistory();
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
    updateSearchSort([
      ["title", "Title"],
      ["artist", "Artist"],
      ["size", "File size"],
    ], serverSort, "Sort server results");
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

function setCurrentSearchQuery(value) {
  if (section === "library") libraryQuery = value;
  else if (section === "playlists") playlistQuery = value;
  else if (section === "storage") storageQuery = value;
  else if (section === "server") serverQuery = value;
}

async function persist({ refreshSidebar = true } = {}) {
  try {
    normalizeState(state);
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
  if (!pending) {
    pending = api.fetchServerArtwork({
      baseURL: state.serverURL,
      token: serverToken,
      profileID: activeProfileID(),
      songID: song.id,
    });
    serverArtworkPending.set(key, pending);
  }
  try {
    const dataURL = await pending;
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
  const id = playlist.id.toLocaleLowerCase();
  state.dirtyPlaylistIDs = [...new Set([...state.dirtyPlaylistIDs, id])];
  state.deletedPlaylistIDs = state.deletedPlaylistIDs.filter((item) => item !== id);
}

function markPlaylistDeleted(playlist) {
  if (!playlist || playlist.isSystem) return;
  const id = playlist.id.toLocaleLowerCase();
  state.dirtyPlaylistIDs = state.dirtyPlaylistIDs.filter((item) => item !== id);
  if (state.knownRemotePlaylistIDs.includes(id)) {
    state.deletedPlaylistIDs = [...new Set([...state.deletedPlaylistIDs, id])];
  }
}

function schedulePlaylistSync() {
  clearTimeout(playlistSyncTimer);
  if (!serverToken.trim()) return;
  playlistSyncTimer = setTimeout(() => syncPlaylistsNow({ automatic: true }), 500);
}

async function syncPlaylistsNow({ automatic = false } = {}) {
  if (playlistSyncInFlight) return playlistSyncInFlight;
  playlistSyncInFlight = (async () => {
    if (!serverToken.trim()) {
      if (!automatic) showNotice("Enter the server access token.");
      return;
    }

    try {
      const serverKey = `${normalizedServerKey(state.serverURL)}#profile=${activeProfileID()}`;
      if (state.playlistSyncServerURL !== serverKey) {
        state.playlistSyncServerURL = serverKey;
        state.playlistRevision = 0;
        state.knownRemotePlaylistIDs = [];
        state.deletedPlaylistIDs = [];
        state.dirtyPlaylistIDs = state.playlists.filter((playlist) => !playlist.isSystem).map((playlist) => playlist.id);
      }

      let remoteDocument = await api.fetchPlaylists({
        baseURL: state.serverURL,
        token: serverToken,
        profileID: activeProfileID(),
      });
      for (let attempt = 0; attempt < 2; attempt += 1) {
        const merge = mergePlaylistDocument(state, remoteDocument);
        if (!merge.needsUpload) {
          applyRemotePlaylistDocument(state, remoteDocument);
          await persist();
          render();
          return;
        }

        const submittedLikesGeneration = likesMutationGeneration;
        const submittedDirtyLikeIDs = [...state.dirtyRemoteLikeSongIDs];
        const result = await api.putPlaylists({
          baseURL: state.serverURL,
          token: serverToken,
          profileID: activeProfileID(),
          document: merge.document,
        });
        if (result.status === 200) {
          state.dirtyPlaylistIDs = [];
          state.deletedPlaylistIDs = [];
          if (likesMutationGeneration === submittedLikesGeneration) {
            state.dirtyRemoteLikeSongIDs = state.dirtyRemoteLikeSongIDs.filter((id) => !submittedDirtyLikeIDs.includes(id));
          }
          state.likesDirty = state.dirtyRemoteLikeSongIDs.length > 0;
          applyRemotePlaylistDocument(state, result.document);
          await persist();
          render();
          if (state.likesDirty) schedulePlaylistSync();
          return;
        }
        remoteDocument = result.document;
      }
      throw new Error("Playlist sync conflicted; try again");
    } catch (error) {
      if (!automatic) showNotice(`Playlist sync failed: ${error.message || "Unknown error"}`);
    }
  })();

  try {
    await playlistSyncInFlight;
  } finally {
    playlistSyncInFlight = null;
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
  const playlistActions = editablePlaylist
    ? `<div class="playlist-track-actions"><button type="button" data-reorder-track="-1" data-playlist-track="${track.id}" title="Move up" aria-label="Move ${escapeHTML(track.title || "track")} up">↑</button><button type="button" data-reorder-track="1" data-playlist-track="${track.id}" title="Move down" aria-label="Move ${escapeHTML(track.title || "track")} down">↓</button><button type="button" data-remove-playlist-track="${track.id}" title="Remove from playlist" aria-label="Remove ${escapeHTML(track.title || "track")} from playlist">×</button></div>`
    : `<span></span>`;
  return `<div class="track-row ${track.id === currentID ? "playing" : ""}${editablePlaylist ? " playlist-draggable" : ""}" data-track="${track.id}" tabindex="0" aria-label="${escapeHTML(actionLabel + reorderLabel)}"${draggableAttributes}>
    <span class="track-number" title="${track.id === currentID && !audio.paused ? "Now playing" : `Track ${index + 1}`}">${track.id === currentID && !audio.paused ? nowPlayingIcon : index + 1}</span>${artwork(track)}
    <div class="track-copy"><strong>${escapeHTML(track.title)}</strong><small>${escapeHTML(track.artist)} / Audio</small></div>
    <span class="album">${escapeHTML(track.album)}</span><span class="track-time">${formatTime(track.duration)}</span>
    <button type="button" class="heart" data-favorite="${track.id}" aria-label="${liked ? "Remove from" : "Add to"} Liked Songs" aria-pressed="${liked}">${liked ? "♥" : "♡"}</button>${playlistActions}
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
    `<button type="button" role="menuitem" data-hero-next>Next Track</button>`,
    `<button type="button" role="menuitem" data-hero-sync>Sync Playlists</button>`,
    editablePlaylist ? `<button class="danger-item" type="button" role="menuitem" data-hero-delete>Delete Playlist</button>` : "",
  ].filter(Boolean).join("") : "";
  const playlistMoreMenu = selectedPlaylist
    ? `<details class="playlist-more" id="playlistMore"><summary title="More options" aria-label="More playlist options"><span aria-hidden="true">•••</span></summary><div class="playlist-menu" role="menu">${playlistMenuItems}</div></details>`
    : "";
  const playlistCapsule = selectedPlaylist
    ? `<div class="playlist-action-cluster"><button class="${shuffle ? "active" : ""}" id="heroShuffle" title="Shuffle" aria-label="Shuffle" aria-pressed="${shuffle}">${shuffleIcon}</button><button id="heroAdd" title="Add songs" aria-label="Add songs">${plusIcon}</button>${playlistMoreMenu}</div>`
    : "";
  const libraryFilters = `<div class="filters${selectedPlaylistID ? "" : " library-top-filters"}"><button class="${libraryFilter === "all" ? "active" : ""}" data-library-filter="all">All songs</button><button class="${libraryFilter === "recent" ? "active" : ""}" data-library-filter="recent">Recently added</button><button class="${libraryFilter === "audio" ? "active" : ""}" data-library-filter="audio">Audio</button></div>`;
  const collectionHeader = selectedPlaylistID
    ? `<div class="hero"><div class="hero-art">≋</div><div><span class="eyebrow">PLAYLIST</span><h1>${escapeHTML(title)}</h1><p>${tracks.length} tracks / Stored locally</p><div class="hero-actions"><button class="primary playlist-play" id="playCollection"><span class="button-icon">${collectionPlaying ? playbackPauseIcon : playbackPlayIcon}</span><span>${collectionPlaying ? "Pause" : "Play"}</span></button>${playlistCapsule}</div></div></div>`
    : libraryFilters;
  content.innerHTML = `<div class="collection-scroll">${collectionHeader}
    ${recentTracks.length ? `<section class="recently-added" aria-labelledby="recentlyAddedTitle"><div class="section-heading"><div><span class="eyebrow">FRESH TO YOUR LIBRARY</span><h2 id="recentlyAddedTitle">Recently Added</h2></div><span>${recentTracks.length} newest</span></div><div class="recent-track-list">${recentTracks.map(recentTrackItem).join("")}</div></section>` : ""}
    ${selectedPlaylistID ? libraryFilters : ""}
    <div class="track-table"><div class="track-header"><span>#</span><span></span><span>Title</span><span>Album</span><span>Time</span><span></span><span>${selectedPlaylist && !selectedPlaylist.isSystem ? "Order" : ""}</span></div>
    ${tracks.length ? tracks.map(trackRow).join("") : `<div class="empty"><b>${selectedPlaylistID ? "This playlist is empty" : "No songs yet"}</b><span>${selectedPlaylistID ? "Like songs or add them from your Library." : "Import audio files or connect your music server."}</span></div>`}</div></div>`;
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
  });
  const deleteButton = document.querySelector("[data-hero-delete]");
  if (deleteButton) deleteButton.onclick = async () => {
    closePlaylistMoreMenu();
    if (!selectedPlaylist || !confirm(`Delete ${selectedPlaylist.name}?`)) return;
    markPlaylistDeleted(selectedPlaylist);
    state.playlists = state.playlists.filter((playlist) => playlist.id !== selectedPlaylist.id);
    selectedPlaylistID = null;
    section = "playlists";
    await persist();
    schedulePlaylistSync();
    render();
  };
  document.querySelectorAll("[data-library-filter]").forEach((button) => button.onclick = () => {
    libraryFilter = button.dataset.libraryFilter;
    renderLibrary();
  });
}

function renderPlaylists() {
  updateTopSearch();
  const playlists = filterPlaylists(state.playlists, state.tracks, playlistQuery);
  content.innerHTML = `<div class="page"><span class="eyebrow">YOUR COLLECTIONS</span><h1>Playlists</h1><p>Organize your music into collections shared across your Resonance devices.</p><div class="playlist-page-actions"><button class="primary" id="pageNewPlaylist">＋ New Playlist</button><button class="secondary" id="pageSyncPlaylists">Sync Playlists</button></div><div class="playlist-grid">${playlists.map((playlist) => `<button class="playlist-card" data-open-playlist="${playlist.id}"><div class="playlist-art">${playlist.isSystem ? "♥" : "♪"}</div><div><strong>${escapeHTML(playlist.name)}</strong><small>${playlist.trackIDs.length} tracks</small></div><span>›</span></button>`).join("") || `<div class="empty"><b>No matching playlists</b><span>Try a different playlist or song name.</span></div>`}</div></div>`;
  $("#pageNewPlaylist").onclick = () => newPlaylist();
  $("#pageSyncPlaylists").onclick = () => syncPlaylistsNow();
  document.querySelectorAll("[data-open-playlist]").forEach((button) => button.onclick = () => navigate("library", button.dataset.openPlaylist));
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
  let tracks = state.tracks.filter((track) => {
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
  state.tracks = state.tracks.filter((track) => !removed.has(track.id));
  state.favorites = state.favorites.filter((id) => !removed.has(id));
  state.playlists.forEach((playlist) => { playlist.trackIDs = playlist.trackIDs.filter((id) => !removed.has(id)); });
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
  if (removed.size) await persist();
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
  const localTracks = state.tracks.filter((track) => !track.remoteID);
  const remoteTracks = state.tracks.filter((track) => track.remoteID);
  const localBytes = localTracks.reduce((sum, track) => sum + (track.size || 0), 0);
  const remoteBytes = remoteTracks.reduce((sum, track) => sum + (track.size || 0), 0);
  const total = Math.max(localBytes + remoteBytes, 1);
  const localDegrees = Math.round(localBytes / total * 360);
  content.innerHTML = `<div class="page storage-page"><div class="page-title-row"><div><span class="eyebrow">ON THIS DEVICE</span><h1>Song Storage</h1></div><div class="page-title-actions"><div class="storage-import-control" id="storageImportControl"><button class="primary storage-import-trigger" id="storageImportMenuButton" type="button" aria-haspopup="menu" aria-expanded="false" aria-controls="storageImportMenu"><span class="button-icon" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M12 3v11m0 0 4-4m-4 4-4-4M5 16v3h14v-3"/></svg></span><span>Import</span><svg class="storage-import-chevron" viewBox="0 0 16 16" aria-hidden="true"><path d="m4 6 4 4 4-4"/></svg></button><div class="storage-import-menu" id="storageImportMenu" role="menu" aria-label="Choose an import type" hidden>${localImportAvailable ? '<button class="storage-import-option" type="button" role="menuitem" data-storage-import="link"><span class="storage-import-option-icon" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M14 4h6v6M20 4l-9 9M10 6H6a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-4"/></svg></span><span><strong>Import from link</strong><small>Spotify or YouTube URL</small></span></button>' : ""}<button class="storage-import-option" type="button" role="menuitem" data-storage-import="files"><span class="storage-import-option-icon" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M4 7.5h6l2-2h8v13H4zM12 10v6m-3-3h6"/></svg></span><span><strong>Import files</strong><small>Choose audio from this device</small></span></button></div></div><button class="secondary" id="storageEdit">${storageEditing ? "Done" : "Edit"}</button></div></div>
    <div class="storage-summary" id="storageSummary"><div class="storage-ring" style="--local:${localDegrees}deg"><span>♪</span></div><div class="storage-stat"><small>Local audio</small><strong>${formatBytes(localBytes)}</strong><span>${localTracks.length} files</span></div><div class="storage-stat"><small>Server downloads</small><strong>${formatBytes(remoteBytes)}</strong><span>${remoteTracks.length} files</span></div><div class="storage-stat"><small>Available</small><strong id="storageAvailable">Calculating…</strong><span id="storageFreePercent">Disk space</span></div></div>
    <div class="segmented storage-tabs"><button class="${storageScope === "songs" ? "active" : ""}" data-storage-scope="songs">Songs</button><button class="${storageScope === "downloads" ? "active" : ""}" data-storage-scope="downloads">Downloads</button><button class="${storageScope === "files" ? "active" : ""}" data-storage-scope="files">Files</button></div>
    ${storageEditing ? `<div class="selection-bar"><span>${selectedStorageIDs.size} selected</span><button class="danger" id="deleteSelectedStorage" ${selectedStorageIDs.size ? "" : "disabled"}>Delete selected</button></div>` : ""}
    <div class="storage-section-heading"><strong>${storageScope === "downloads" ? "DOWNLOADED FROM SERVER" : storageScope === "files" ? "IMPORTED ON THIS PC" : "ALL SONGS"}</strong><span>${tracks.length} songs</span></div>
    <div class="storage-list redesigned">${tracks.map((track) => `<div class="storage-row ${storageEditing ? "selecting" : ""}"><button class="storage-select ${selectedStorageIDs.has(track.id) ? "selected" : ""}" data-storage-select="${track.id}" ${storageEditing ? "" : "hidden"}>${selectedStorageIDs.has(track.id) ? "✓" : "○"}</button>${artwork(track)}<span class="track-details"><strong>${escapeHTML(track.title)}</strong><small>${escapeHTML(track.artist || "Unknown Artist")} • ${escapeHTML(track.album || "Unknown Album")}</small></span><span class="storage-size">${formatBytes(track.size)}</span><button class="row-menu" data-delete="${track.id}" title="Remove from this device">•••</button></div>`).join("") || `<div class="empty"><b>No matching songs</b><span>Try another filter or import audio.</span></div>`}</div></div>`;
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
  document.querySelectorAll("[data-storage-scope]").forEach((button) => button.onclick = () => { storageScope = button.dataset.storageScope; renderStorage(); });
  document.querySelectorAll("[data-storage-select]").forEach((button) => button.onclick = () => { selectedStorageIDs.has(button.dataset.storageSelect) ? selectedStorageIDs.delete(button.dataset.storageSelect) : selectedStorageIDs.add(button.dataset.storageSelect); renderStorage(); });
  if ($("#deleteSelectedStorage")) $("#deleteSelectedStorage").onclick = async () => {
    if (selectedStorageIDs.size && confirm(`Remove ${selectedStorageIDs.size} selected song${selectedStorageIDs.size === 1 ? "" : "s"} from this device?`)) await deleteStoredTracks([...selectedStorageIDs]);
  };
  document.querySelectorAll("[data-delete]").forEach((button) => button.onclick = async () => {
    const track = state.tracks.find((item) => item.id === button.dataset.delete);
    if (!track || !confirm(`Remove ${track.title} from this device?`)) return;
    await deleteStoredTracks([track.id]);
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
  const downloaded = serverCatalog.filter((song) => state.tracks.some((track) => track.remoteID === song.id)).length;
  const filteredCount = filteredServerCatalog().length;
  const playlistCount = state.playlists.filter((playlist) => !playlist.isSystem).length;
  const connected = serverCatalog.length > 0 || serverConnectionText.startsWith("Connected");
  const selectLabel = !serverSelecting
    ? "Choose songs to download"
    : selectedRemoteIDs.size
      ? `Download ${selectedRemoteIDs.size} selected song${selectedRemoteIDs.size === 1 ? "" : "s"}`
      : "Cancel song selection";
  content.innerHTML = `<div class="page server-page">
    <div class="server-heading"><h1>Music Server</h1><div class="server-status-line">
      <span id="serverStatus" class="connection-pill ${connected ? "connected" : ""}">● ${escapeHTML(connected ? "Connected" : serverConnectInFlight ? "Connecting" : "Offline")}</span>
      <span class="server-connection-detail" role="status" aria-live="polite">${escapeHTML(serverConnectionText)}</span>
      <button class="server-url" id="serverSettings" title="Edit server connection"><span>${escapeHTML(state.serverURL || "Add a server connection")}</span><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m4 20 4.5-1 10-10-3.5-3.5-10 10zM13.5 7l3.5 3.5"/></svg></button>
      <span class="server-dot">•</span><span class="server-inline-metric purple">${serverSongIcon}<strong id="serverSongCount">${serverCatalog.length}</strong><span>songs</span></span>
      <span class="server-dot">•</span><span class="server-inline-metric violet">${serverPlaylistMetricIcon}<strong>${playlistCount}</strong><span>playlists</span></span>
      <span class="server-dot">•</span><span class="server-inline-metric green">${serverDeviceIcon}<strong>${downloaded}</strong><span>on device</span></span>
    </div></div>
    <div class="server-library-bar"><div><strong>SERVER LIBRARY</strong><span id="remoteCount">${filteredCount} songs</span></div><div class="server-actions">
      <button id="uploadServer" title="Upload songs" aria-label="Upload songs">${serverUploadIcon}</button>
      <button id="syncAll" title="Download all songs" aria-label="Download all songs">${serverDownloadIcon}</button>
      <button id="syncSelected" class="${serverSelecting ? "active" : ""}" title="${selectLabel}" aria-label="${selectLabel}" aria-pressed="${serverSelecting}">${serverSelectIcon}${selectedRemoteIDs.size ? `<b>${selectedRemoteIDs.size}</b>` : ""}</button>
      <button id="syncServerPlaylists" title="Sync playlists" aria-label="Sync playlists">${serverPlaylistIcon}</button>
    </div></div>
    <div class="server-table-head ${serverSelecting ? "selecting" : ""}">${serverSelecting ? "<span></span>" : ""}<span></span><button data-server-sort="title">TITLE ${serverSort === "title" ? "⌃" : ""}</button><button data-server-sort="artist">ARTIST ${serverSort === "artist" ? "⌃" : ""}</button><span>ALBUM</span><span>DURATION</span><span></span></div>
    <div id="remoteSongs" class="remote-list redesigned server-library">${filteredCount ? remoteRows() : `<div class="empty"><b>${serverCatalog.length ? "No matching songs" : "No server songs"}</b><span>${serverConnectInFlight ? "Connecting to your server…" : serverCatalog.length ? "Try another search or filter." : "Open connection settings to connect."}</span></div>`}</div>
  </div>`;
  $("#serverSettings").onclick = openServerSettings;
  document.querySelectorAll("[data-server-sort]").forEach((button) => button.onclick = () => { serverSort = button.dataset.serverSort; updateTopSearch(); renderServer(); });
  $("#syncSelected").onclick = () => {
    if (!serverSelecting) {
      serverSelecting = true;
      selectedRemoteIDs.clear();
      renderServer();
    } else if (selectedRemoteIDs.size) {
      serverAction("selected");
    } else {
      serverSelecting = false;
      renderServer();
    }
  };
  $("#syncAll").onclick = () => serverAction("all");
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
    const onDevice = state.tracks.some((track) => track.remoteID === song.id);
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
    const onDevice = state.tracks.some((track) => track.remoteID === song.id);
    const selected = selectedRemoteIDs.has(song.id);
    const duration = Number(song.duration) > 0 ? formatTime(Number(song.duration)) : "—";
    return `<div class="remote-row ${serverSelecting ? "selecting" : ""} ${selected ? "selected" : ""}" data-remote-row="${song.id}">
      <button class="remote-check ${selected ? "selected" : ""}" data-select-remote="${song.id}" ${serverSelecting ? "" : "hidden"} aria-label="${selected ? "Deselect" : "Select"} ${escapeHTML(song.title || song.name)}">${selected ? "✓" : ""}</button>
      ${artwork(song, { animateLoading: true })}
      <span class="server-song-title"><strong>${escapeHTML(song.title || song.name)}</strong>${onDevice ? '<small>On device</small>' : ""}</span>
      <span class="server-cell">${escapeHTML(song.artist || "Unknown Artist")}</span>
      <span class="server-cell server-album">${escapeHTML(song.album || "Server Library")}</span>
      <span class="server-cell server-duration">${duration}</span>
      <button class="row-menu" data-delete-remote="${song.id}" title="Delete from server" aria-label="Delete ${escapeHTML(song.title || song.name)} from server">•••</button>
    </div>`;
  }).join("");
}

function bindRemoteRows() {
  document.querySelectorAll("[data-select-remote]").forEach((button) => button.onclick = () => { selectedRemoteIDs.has(button.dataset.selectRemote) ? selectedRemoteIDs.delete(button.dataset.selectRemote) : selectedRemoteIDs.add(button.dataset.selectRemote); renderServer(); });
  document.querySelectorAll("[data-remote-row]").forEach((row) => row.onclick = (event) => {
    if (!serverSelecting || event.target.closest("button")) return;
    const id = row.dataset.remoteRow;
    selectedRemoteIDs.has(id) ? selectedRemoteIDs.delete(id) : selectedRemoteIDs.add(id);
    renderServer();
  });
  document.querySelectorAll("[data-delete-remote]").forEach((button) => button.onclick = async () => {
    const song = serverCatalog.find((item) => item.id === button.dataset.deleteRemote);
    if (!song || !confirm(`Delete ${song.title || song.name} from the server?`)) return;
    await saveServerForm();
    await api.deleteServerSong({ baseURL: state.serverURL, adminToken: serverAdminToken, profileID: activeProfileID(), songID: song.id });
    await serverAction("catalog");
  });
}

function renderProfileOptions(selectedID = activeProfileID()) {
  const select = $("#syncProfile");
  if (!select) return;
  select.innerHTML = state.syncProfiles.map((profile) =>
    `<option value="${escapeHTML(profile.id)}">${escapeHTML(profile.name)}</option>`).join("");
  select.value = state.syncProfiles.some((profile) => profile.id === selectedID) ? selectedID : "default";
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

async function openProfileSwitcher() {
  closeProfileMenu();
  updateProfileSwitchDialog();
  const dialog = $("#profileSwitchDialog");
  const status = $("#profileSwitchStatus");
  dialog.showModal();
  $("#profileSwitchQuery").focus();
  $("#profileSwitchQuery").select();
  if (!state.serverURL || !serverToken) {
    status.textContent = "Not connected";
    return;
  }
  status.textContent = "Checking server profiles…";
  try {
    const response = await api.fetchProfiles({ baseURL: state.serverURL, token: serverToken });
    state.syncProfiles = response.profiles || [];
    renderProfileOptions();
    updateProfileSwitchDialog({ resetQuery: false });
    status.textContent = "Connected";
  } catch (error) {
    status.textContent = error.message || "Could not load profiles";
  }
}

async function activateProfile(profileID) {
  if (!profileID || profileID === activeProfileID()) return;
  state.syncProfileID = profileID;
  state.playlists = state.playlists.filter((playlist) => playlist.isSystem);
  state.favorites = state.favorites.filter((trackID) => !state.tracks.find((track) => track.id === trackID)?.remoteID);
  state.playlistRevision = 0;
  state.knownRemotePlaylistIDs = [];
  state.dirtyPlaylistIDs = [];
  state.deletedPlaylistIDs = [];
  state.remoteLikedSongIDs = [];
  state.dirtyRemoteLikeSongIDs = [];
  state.likesDirty = false;
  state.playlistSyncServerURL = `${normalizedServerKey(state.serverURL)}#profile=${profileID}`;
  serverCatalog = [];
  selectedRemoteIDs.clear();
  selectedPlaylistID = null;
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
  state.serverURL = $("#serverURL")?.value.trim() || state.serverURL;
  serverToken = $("#serverToken")?.value || serverToken;
  serverAdminToken = $("#serverAdminToken")?.value || serverAdminToken;
  await activateProfile($("#syncProfile")?.value || activeProfileID());
  await api.saveServerCredentials({ clientToken: serverToken, adminToken: serverAdminToken });
  await persist();
  updateProfileControl();
  schedulePlaylistSync();
  scheduleListeningHistorySync();
}

function renderSettings() {
  updateTopSearch();
  content.innerHTML = `<div class="page settings-placeholder">
    <section class="settings-placeholder-card" aria-labelledby="settingsPlaceholderTitle">
      <span class="settings-placeholder-icon" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.64 5.64l2.12 2.12M16.24 16.24l2.12 2.12M18.36 5.64l-2.12 2.12M7.76 16.24l-2.12 2.12"/><circle cx="12" cy="12" r="3.5"/></svg></span>
      <span class="eyebrow">SETTINGS</span>
      <h1 id="settingsPlaceholderTitle">Under construction</h1>
      <p>This part of Resonance is still being built.</p>
    </section>
  </div>`;
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
    row.oncontextmenu = (event) => openTrackContextMenu(event, row.dataset.track);
    row.onkeydown = async (event) => {
      if (event.target !== row) return;
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        play(state.tracks.find((track) => track.id === row.dataset.track), playbackTracks, { playlistID: selectedPlaylistID });
        return;
      }
      if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) {
        event.preventDefault();
        openTrackContextMenu(event, row.dataset.track);
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
  document.querySelectorAll("[data-reorder-track]").forEach((button) => button.onclick = async (event) => {
    event.stopPropagation();
    const playlist = state.playlists.find((item) => item.id === selectedPlaylistID && !item.isSystem);
    if (!playlist) return;
    const index = playlist.trackIDs.indexOf(button.dataset.playlistTrack);
    const destination = index + Number(button.dataset.reorderTrack);
    if (index < 0 || destination < 0 || destination >= playlist.trackIDs.length) return;
    const [trackID] = playlist.trackIDs.splice(index, 1);
    playlist.trackIDs.splice(destination, 0, trackID);
    updatePlaylistRemoteSongIDs(state, playlist);
    markPlaylistDirty(playlist);
    if (activePlaybackPlaylistID === playlist.id) setPlaybackContext(tracksForPlaylist(state, playlist.id), playlist.id);
    await persist();
    schedulePlaylistSync();
    renderLibrary();
  });
  document.querySelectorAll("[data-remove-playlist-track]").forEach((button) => button.onclick = async (event) => {
    event.stopPropagation();
    const playlist = state.playlists.find((item) => item.id === selectedPlaylistID && !item.isSystem);
    if (!playlist) return;
    playlist.trackIDs = playlist.trackIDs.filter((id) => id !== button.dataset.removePlaylistTrack);
    updatePlaylistRemoteSongIDs(state, playlist);
    markPlaylistDirty(playlist);
    if (activePlaybackPlaylistID === playlist.id) setPlaybackContext(tracksForPlaylist(state, playlist.id), playlist.id);
    await persist();
    schedulePlaylistSync();
    renderLibrary();
  });
}

function closeTrackContextMenu() {
  const menu = $("#trackContextMenu");
  menu.hidden = true;
  menu.innerHTML = "";
  menu.onkeydown = null;
}

function openTrackContextMenu(event, trackID) {
  event.preventDefault();
  const returnFocus = event.currentTarget;
  const menu = $("#trackContextMenu");
  const track = state.tracks.find((item) => item.id === trackID);
  if (!track) return;
  const activePlaylist = state.playlists.find((item) => item.id === selectedPlaylistID && !item.isSystem);
  const playlists = state.playlists.filter((item) => !item.isSystem && item.id !== activePlaylist?.id);
  const removeAction = activePlaylist
    ? `<button class="context-danger" role="menuitem" data-context-remove-playlist-track><span>−</span>Remove from ${escapeHTML(activePlaylist.name)}</button><div class="context-divider"></div><div class="context-section-label">ADD TO ANOTHER PLAYLIST</div>`
    : "";
  menu.innerHTML = `<div class="context-heading"><small>${activePlaylist ? "PLAYLIST TRACK" : "ADD TO PLAYLIST"}</small><strong>${escapeHTML(track.title)}</strong><em>${escapeHTML(track.artist || "Unknown artist")}</em></div>${removeAction}${playlists.length ? playlists.map((playlist) => {
    const added = playlist.trackIDs.includes(trackID);
    return `<button role="menuitem" data-context-playlist="${escapeHTML(playlist.id)}" ${added ? "disabled" : ""}><span>${added ? "✓" : "＋"}</span>${escapeHTML(playlist.name)}</button>`;
  }).join("") : `<div class="context-empty">${activePlaylist ? "No other playlists yet" : "No playlists yet"}</div>`}<div class="context-divider"></div><button class="context-create" role="menuitem" data-context-new><span>＋</span>Create new playlist…</button>`;
  menu.hidden = false;
  const anchor = returnFocus?.getBoundingClientRect?.();
  const requestedX = Number(event.clientX) > 0 ? Number(event.clientX) : (anchor?.left ?? 8) + 24;
  const requestedY = Number(event.clientY) > 0 ? Number(event.clientY) : (anchor?.top ?? 8) + 24;
  menu.style.left = `${Math.max(8, Math.min(requestedX, innerWidth - menu.offsetWidth - 8))}px`;
  menu.style.top = `${Math.max(8, Math.min(requestedY, innerHeight - menu.offsetHeight - 8))}px`;
  menu.onkeydown = (keyEvent) => {
    const items = [...menu.querySelectorAll('[role="menuitem"]:not(:disabled)')];
    const currentIndex = items.indexOf(document.activeElement);
    if (keyEvent.key === "Escape") {
      keyEvent.preventDefault();
      closeTrackContextMenu();
      returnFocus?.focus?.();
    } else if (["ArrowDown", "ArrowUp", "Home", "End"].includes(keyEvent.key) && items.length) {
      keyEvent.preventDefault();
      const nextItemIndex = keyEvent.key === "Home" ? 0
        : keyEvent.key === "End" ? items.length - 1
          : (currentIndex + (keyEvent.key === "ArrowUp" ? -1 : 1) + items.length) % items.length;
      items[nextItemIndex].focus();
    }
  };
  requestAnimationFrame(() => menu.querySelector('[role="menuitem"]:not(:disabled)')?.focus());
  const removeButton = menu.querySelector("[data-context-remove-playlist-track]");
  if (removeButton) removeButton.onclick = async () => {
    activePlaylist.trackIDs = activePlaylist.trackIDs.filter((id) => id !== trackID);
    updatePlaylistRemoteSongIDs(state, activePlaylist);
    markPlaylistDirty(activePlaylist);
    if (activePlaybackPlaylistID === activePlaylist.id) {
      setPlaybackContext(tracksForPlaylist(state, activePlaylist.id), activePlaylist.id);
    }
    closeTrackContextMenu();
    await persist();
    schedulePlaylistSync();
    renderLibrary();
  };
  menu.querySelectorAll("[data-context-playlist]").forEach((button) => button.onclick = async () => {
    const playlist = state.playlists.find((item) => item.id === button.dataset.contextPlaylist);
    if (playlist && !playlist.trackIDs.includes(trackID)) {
      playlist.trackIDs.push(trackID);
      updatePlaylistRemoteSongIDs(state, playlist);
      markPlaylistDirty(playlist);
      if (activePlaybackPlaylistID === playlist.id) setPlaybackContext(tracksForPlaylist(state, playlist.id), playlist.id);
    }
    closeTrackContextMenu();
    await persist();
    schedulePlaylistSync();
  });
  menu.querySelector("[data-context-new]").onclick = () => {
    closeTrackContextMenu();
    newPlaylist(trackID);
  };
}

async function importAudio() {
  try {
    const tracks = await api.importAudio();
    if (!tracks.length) return;
    state.tracks.push(...tracks);
    if (!currentID && tracks[0]) {
      currentID = tracks[0].id;
      state.currentTrackID = currentID;
      setPlaybackContext(state.tracks, null);
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
  const selected = document.querySelector('input[name="localImportCandidate"]:checked');
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
  const showPreviews = mediaKind === "audio" && candidates.length > 1;
  const selectedKind = document.querySelector(`input[name="localImportMediaKind"][value="${mediaKind}"]`);
  if (selectedKind) selectedKind.checked = true;
  $("#localImportResolved").hidden = false;
  $("#localImportSyncRow").hidden = false;
  void renderLocalImportArtwork(track, candidates, mediaKind);
  $("#localImportTrackTitle").textContent = track.title || "Untitled";
  $("#localImportTrackMeta").textContent = [track.artist, track.album, track.durationSeconds ? formatTime(track.durationSeconds) : null]
    .filter(Boolean).join(" • ");
  $("#localImportCandidates").innerHTML = candidates.map((candidate, index) => `<label class="local-import-candidate">
    <input type="radio" name="localImportCandidate" value="${index}" ${index === 0 ? "checked" : ""}>
    <span><strong>${escapeHTML(candidate.title || "Untitled source")}</strong><small>${escapeHTML(localImportCandidateDetails(candidate).filter(Boolean).join(" • "))}</small></span>
    <span class="local-import-confidence">${escapeHTML(candidate.quality || candidate.confidence || "file")}</span>
    ${showPreviews ? `<button class="local-import-preview-button" type="button" data-local-import-preview="${index}" aria-label="Preview ${escapeHTML(candidate.title || "source")}" aria-pressed="false" title="${localImportCandidateCanPreview(candidate) ? "Preview source" : "Preview unavailable for this source"}" ${localImportCandidateCanPreview(candidate) ? "" : "disabled"}><svg class="preview-play-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5v14l11-7z"/></svg><svg class="preview-pause-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M8 6v12M16 6v12"/></svg></button>` : ""}
  </label>`).join("");
  document.querySelectorAll('input[name="localImportCandidate"]').forEach((input) => input.onchange = updateLocalImportSyncForSelection);
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
  $("#confirmLocalImport").disabled = false;
  const confirmLabel = mediaKind === "video" ? "Download video" : "Download audio";
  $("#confirmLocalImport").title = confirmLabel;
  $("#confirmLocalImport").setAttribute("aria-label", confirmLabel);
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

async function confirmLinkImport() {
  if (localImportRunning || !localImportResolution) return;
  const selected = document.querySelector('input[name="localImportCandidate"]:checked');
  const candidate = localImportResolution.candidates[Number(selected?.value) || 0];
  const mediaKind = localImportResolution.mediaKind === "video" ? "video" : "audio";
  if (!candidate) {
    showLocalImportError({ stage: "awaiting_selection", message: `Choose one ${mediaKind} source to import.` });
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
        setPlaybackContext(state.tracks, null);
      }
      await persist();
      render();
      updateChrome();
      setLocalImportStage({ stage: "local_complete" });
      showNotice(response.result.serverBacked
        ? `Imported ${importedTrack.title} on this device and ${activeProfile().name || "the active server profile"}.`
        : `${mediaKind === "video" ? "Downloaded" : "Imported"} ${importedTrack.title} on this device.`, "status");
    }

    if (!response.result.serverBacked && $("#localImportSync").checked && importedTrack?.filePath && response.result.kind === "created") {
      setLocalImportStage({ stage: "syncing", profileID: activeProfileID() });
      const uploaded = await api.uploadLocalImport({
        baseURL: state.serverURL,
        adminToken: serverAdminToken,
        profileID: activeProfileID(),
        filePath: importedTrack.filePath,
      });
      if (!uploaded?.ok) {
        showLocalImportError(uploaded?.error || { stage: "syncing", message: "The song was saved locally, but its optional profile upload failed." });
        return;
      }
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
  const tracks = state.tracks.filter((track) =>
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
  if (serverConnectInFlight) return;
  const url = $("#serverURL")?.value.trim() || state.serverURL;
  const token = $("#serverToken")?.value || serverToken;
  serverToken = token;
  const status = $("#serverStatus");
  await saveServerForm();
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
      const result = await api.syncServer({ baseURL: url, token, profileID: activeProfileID(), existing: state.tracks, songIDs });
      catalog = result.catalog;
      transferCancelled = Boolean(result.cancelled || serverTransferCancelRequested);
      mergeSyncedTracks(state, result);
      serverConnectionText = transferCancelled
        ? `Download cancelled${result.downloaded.length ? ` • ${result.downloaded.length} completed` : ""}`
        : `Synced ${result.downloaded.length} new song${result.downloaded.length === 1 ? "" : "s"}`;
      selectedRemoteIDs.clear();
      await persist();
    } else {
      catalog = await api.fetchCatalog({ baseURL: url, token, profileID: activeProfileID() });
      serverConnectionText = `Connected • ${catalog.count} song${catalog.count === 1 ? "" : "s"}`;
    }
    if (catalog) {
      state.serverURL = url;
      serverCatalog = catalog.songs || [];
      hydrateServerCatalogArtwork(serverCatalog);
    }
    await persist();
    renderSidebar();
    if (!transferCancelled) await syncPlaylistsNow({ automatic: true });
  } catch (error) {
    serverConnectionText = serverTransferCancelRequested ? "Download cancelled" : friendlyIPCError(error, "Connection failed");
    if (!serverTransferCancelRequested) showNotice(serverConnectionText);
  } finally {
    serverConnectInFlight = false;
    if (mode !== "catalog") {
      hideServerTransfer("server");
      serverTransferCancelRequested = false;
    }
    if (section === "server") renderServer();
  }
}

async function uploadServerSongs() {
  await saveServerForm();
  const status = $("#serverStatus");
  serverTransferCancelRequested = false;
  updateServerTransfer({ direction: "upload", currentFile: "Choose songs to upload…", completed: 0, total: 1 });
  try {
    const result = await api.uploadServer({ baseURL: state.serverURL, adminToken: serverAdminToken, profileID: activeProfileID() });
    const cancelled = Boolean(result.cancelled || serverTransferCancelRequested);
    serverConnectionText = cancelled
      ? `Upload cancelled${result.uploaded ? ` • ${result.uploaded} completed` : ""}`
      : `Uploaded ${result.uploaded} song${result.uploaded === 1 ? "" : "s"}`;
    if (status) status.textContent = serverConnectionText;
    if (cancelled) {
      const catalog = await api.fetchCatalog({ baseURL: state.serverURL, token: serverToken, profileID: activeProfileID() });
      serverCatalog = catalog.songs || [];
      hydrateServerCatalogArtwork(serverCatalog);
      if (section === "server") renderServer();
    } else {
      await serverAction("catalog");
    }
  } catch (error) {
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

function play(track, queue = null, options = {}) {
  if (!track) return;
  const { recordHistory = true, playlistID = activePlaybackPlaylistID } = options;
  if (Array.isArray(queue) && queue.length) setPlaybackContext(queue, playlistID);
  else if (!activePlaybackQueueIDs.includes(track.id)) setPlaybackContext(state.tracks, null);
  if (recordHistory && currentID && currentID !== track.id) history.push(currentID);
  if (activeListeningEntryID) {
    updateListeningSession();
    persistInBackground();
    scheduleListeningHistorySync();
  }
  activeListeningEntryID = null;
  lastListeningPosition = 0;
  lastPersistedListeningSeconds = 0;
  pendingRestorePosition = null;
  currentID = track.id;
  state.currentTrackID = currentID;
  state.position = 0;
  audio.src = track.fileUrl;
  audio.volume = normalizedVolume(state.volume);
  audio.playbackRate = Number($("#speed").value) || 1;
  void requestPlayback();
  persistInBackground(); updateChrome(); render();
}

function toggle() {
  const track = currentTrack();
  if (!track) { if (state.tracks[0]) play(state.tracks[0]); return; }
  if (!audio.currentSrc && !audio.src) { play(track); return; }
  if (audio.paused) void requestPlayback();
  else audio.pause();
  updateChrome();
}

function move(direction, recordHistory = direction > 0) {
  const tracks = activePlaybackTracks();
  const index = nextIndex(tracks, currentID, direction, shuffle);
  if (index >= 0) play(tracks[index], null, { recordHistory });
}

function previous() {
  if (audio.currentTime > 3) {
    audio.currentTime = 0;
    state.position = 0;
    return;
  }
  const previousID = history.pop();
  const track = previousID && state.tracks.find((item) => item.id === previousID);
  if (track) play(track, null, { recordHistory: false });
  else move(-1, false);
}

function toggleFavorite(id) {
  const track = state.tracks.find((item) => item.id === id);
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
  dialog.showModal();
  requestAnimationFrame(() => $("#playlistName").focus());
}

function renderSidebar() {
  normalizeState(state);
  $("#sidebarPlaylists").innerHTML = state.playlists.map((playlist) => `<button data-side-playlist="${playlist.id}"><span>${playlist.isSystem ? "♥" : "♪"}</span><div><strong>${escapeHTML(playlist.name)}</strong><small>${playlist.trackIDs.length} tracks</small></div></button>`).join("");
  document.querySelectorAll("[data-side-playlist]").forEach((button) => button.onclick = () => navigate("library", button.dataset.sidePlaylist));
}

function renderQueue() {
  if (!$("#queue")) return;
  const tracks = activePlaybackTracks();
  const index = tracks.findIndex((track) => track.id === currentID);
  const queue = index < 0 ? tracks : [...tracks.slice(index + 1), ...tracks.slice(0, index)];
  $("#queue").innerHTML = queue.slice(0, 12).map((track) => `<button data-queue="${track.id}">${artwork(track)}<span><strong>${escapeHTML(track.title)}</strong><small>${escapeHTML(track.artist)}</small></span><time>${formatTime(track.duration)}</time></button>`).join("") || `<div class="empty"><span>Queue is empty</span></div>`;
  document.querySelectorAll("[data-queue]").forEach((button) => button.onclick = () => play(state.tracks.find((track) => track.id === button.dataset.queue)));
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

document.querySelectorAll(".nav").forEach((button) => button.onclick = () => navigate(button.dataset.section));
$("#navBack").onclick = () => { if (navigationIndex > 0) { navigationIndex -= 1; applyNavigation(navigationHistory[navigationIndex]); } };
$("#navForward").onclick = () => { if (navigationIndex + 1 < navigationHistory.length) { navigationIndex += 1; applyNavigation(navigationHistory[navigationIndex]); } };
document.querySelectorAll("[data-action=toggle]").forEach((button) => button.onclick = toggle);
document.querySelectorAll("[data-action=next]").forEach((button) => button.onclick = () => move(1));
document.querySelectorAll("[data-action=previous]").forEach((button) => button.onclick = previous);
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
$("#closeAddSongs").onclick = () => $("#addSongsDialog").close();
$("#closeClipEditor").onclick = () => $("#clipEditorDialog").close();
$("#clipEditorTrack").onchange = () => renderClipEditorTrack({ resetRange: true });
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
  if (event.target === $("#clipEditorDialog")) $("#clipEditorDialog").close();
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
    if (resolution.fellBackToDefault) {
      showNotice(`Profile “${query}” was not found. Switched to ${profile.name || "Default"}.`, "status");
    }
  } catch (error) {
    status.textContent = error.message || "Could not switch profiles.";
  } finally {
    submit.disabled = false;
  }
};
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
  await persist();
};
$("#speed").onchange = (event) => {
  audio.playbackRate = Number(event.target.value);
  state.playbackRate = audio.playbackRate;
  persistInBackground();
};
$("#seek").oninput = (event) => {
  if (audio.duration) audio.currentTime = audio.duration * Number(event.target.value) / 1000;
  event.target.setAttribute("aria-valuetext", `${formatTime(audio.currentTime)} of ${formatTime(audio.duration)}`);
  paintRange(event.target);
};
audio.ontimeupdate = () => {
  if (pendingRestorePosition !== null) return;
  $("#elapsed").textContent = formatTime(audio.currentTime);
  $("#duration").textContent = formatTime(audio.duration);
  $("#seek").value = audio.duration ? String(Math.round(audio.currentTime / audio.duration * 1000)) : "0";
  $("#seek").setAttribute("aria-valuetext", `${formatTime(audio.currentTime)} of ${formatTime(audio.duration)}`);
  paintRange($("#seek"));
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
  repeat ? play(currentTrack(), null, { recordHistory: false }) : move(1);
};
audio.onerror = () => {
  updateChrome();
  showNotice("This song could not be played. The file may be missing, inaccessible, or unsupported.");
};
audio.onloadedmetadata = async () => {
  const track = currentTrack();
  if (pendingRestorePosition !== null) {
    if (Number.isFinite(audio.duration) && audio.duration > 0) {
      audio.currentTime = Math.min(pendingRestorePosition, Math.max(0, audio.duration - 0.25));
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
$("#speed").value = String(state.playbackRate || 1);
$("#volumeText").textContent = `${Math.round(state.volume * 100)}%`;
$("#volume").setAttribute("aria-valuetext", `${Math.round(state.volume * 100)} percent`);
const restoredCurrentID = state.currentTrackID && state.tracks.some((track) => track.id === state.currentTrackID) ? state.currentTrackID : null;
currentID = restoredCurrentID || state.tracks[0]?.id || null;
activePlaybackQueueIDs = state.playbackQueueIDs.length ? [...state.playbackQueueIDs] : state.tracks.map((track) => track.id);
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
api.onUpdateStatus((value) => {
  const status = $("#updateStatus");
  const install = $("#installUpdate");
  if (!status || !install) return;
  if (value.type === "checking") status.textContent = "Checking GitHub…";
  else if (value.type === "available") status.textContent = `Downloading ${value.version}…`;
  else if (value.type === "downloading") status.textContent = `Downloading… ${value.percent}%`;
  else if (value.type === "ready") { status.textContent = `${value.version} is ready`; install.hidden = false; }
  else if (value.type === "current") status.textContent = "You’re up to date";
  else if (value.type === "error") status.textContent = value.message || "Update check failed";
});
$("#checkForUpdates").onclick = async () => {
  try {
    const result = await api.checkForUpdates();
    if (!result.supported) $("#updateStatus").textContent = "Available in installed builds";
  } catch (error) {
    $("#updateStatus").textContent = error.message || "Update check failed";
  }
};
$("#installUpdate").onclick = () => api.installUpdate();
render(); updateChrome();
syncPlaylistsNow({ automatic: true });
syncListeningHistoryNow();
setInterval(() => syncPlaylistsNow({ automatic: true }), 60000);
setInterval(() => syncListeningHistoryNow(), 60000);
