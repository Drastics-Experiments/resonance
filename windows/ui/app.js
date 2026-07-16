import {
  applyRemotePlaylistDocument,
  createEmptyState,
  filterPlaylists,
  filterTracks,
  formatTime,
  mergePlaylistDocument,
  mergeSyncedTracks,
  nextIndex,
  normalizedVolume,
  normalizeState,
  tracksForPlaylist,
  updatePlaylistRemoteSongIDs,
} from "./core.js";

const api = window.likedSongs;
const audio = document.querySelector("#audio");
const content = document.querySelector("#content");
let state = createEmptyState();
let currentID = null;
let section = "library";
let selectedPlaylistID = null;
let libraryFilter = "all";
let serverToken = "";
let serverAdminToken = "";
let serverCatalog = [];
let selectedRemoteIDs = new Set();
let shuffle = false;
let repeat = false;
let history = [];
let activePlaybackQueueIDs = [];
let activePlaybackPlaylistID = null;
let pendingRestorePosition = null;
let playbackProgressTimer = null;
let navigationHistory = [{ section: "library", playlistID: null }];
let navigationIndex = 0;
let pendingPlaylistTrackID = null;
let addSongsPlaylistID = null;
let libraryQuery = "";
let playlistQuery = "";
let playlistSyncText = "Not synced";
let playlistSyncInFlight = null;
let playlistSyncTimer = null;
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
let draggingPlaylistTrackID = null;
let draggingPlaylistTargetID = null;
let draggingPlaylistInsertAfter = false;
let playlistDragPreviewKey = "";
let playlistDragFloatingRow = null;

const $ = (selector) => document.querySelector(selector);
const shuffleIcon = `<svg class="shuffle-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h2.5a5 5 0 0 1 4 2l5 7a5 5 0 0 0 4 2H21"/><path d="m17 13 4 4-4 4"/><path d="M3 18h2.5a5 5 0 0 0 4-2l5-7a5 5 0 0 1 4-2H21"/><path d="m17 3 4 4-4 4"/></svg>`;
const playlistNoteIcon = `<svg class="playlist-note-icon" viewBox="0 0 120 140" aria-hidden="true"><path d="M79 22v72.5c0 13.5-11.6 24.5-26 24.5S27 108 27 94.5 38.6 70 53 70c4.1 0 8 .9 11.5 2.5V30.8c0-5.3 3.7-9.9 8.9-11l31-6.6c4.4-.9 8.6 2.4 8.6 6.9v25.3c0 3.3-2.3 6.2-5.6 6.9L79 58.4"/></svg>`;
const likedSongsIcon = `<svg class="liked-songs-icon" viewBox="0 0 120 120" aria-hidden="true"><path d="M60 104C51 96 23 76 17 52 11 28 39 15 60 38c21-23 49-10 43 14-6 24-34 44-43 52Z"/></svg>`;
const plusIcon = `<svg class="plus-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>`;
const checkIcon = `<svg class="check-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="m5 12.5 4.3 4.3L19 7"/></svg>`;
const playbackPlayIcon = `<svg class="transport-icon" viewBox="0 0 24 24" aria-hidden="true"><path class="icon-fill" d="M8 5v14l11-7z"/></svg>`;
const playbackPauseIcon = `<svg class="transport-icon" viewBox="0 0 24 24" aria-hidden="true"><rect class="icon-fill" x="6" y="5" width="4.5" height="14" rx="1.5"/><rect class="icon-fill" x="13.5" y="5" width="4.5" height="14" rx="1.5"/></svg>`;
const nowPlayingIcon = `<svg class="now-playing-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M3.5 9.5h4l5-4v13l-5-4h-4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7"/><path d="M18.5 5.5a9 9 0 0 1 0 13"/></svg>`;
const serverUploadIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 16V4m0 0L7.5 8.5M12 4l4.5 4.5"/><path d="M5 14v5h14v-5"/></svg>`;
const serverDownloadIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 4v12m0 0 4.5-4.5M12 16l-4.5-4.5"/><path d="M5 19h14"/></svg>`;
const serverSelectIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 4h10v9H7z"/><path d="M4 16v3h16v-3"/><path d="M12 7v7m0 0 2.5-2.5M12 14l-2.5-2.5"/></svg>`;
const serverRefreshIcon = `<svg class="server-refresh-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M20 7v5h-5"/><path d="M19 12a7 7 0 1 0-2.05 4.95"/></svg>`;
const serverSongIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="9" cy="18" r="3"/><path d="M12 18V5l8-2v13"/><circle cx="17" cy="16" r="3"/></svg>`;
const serverPlaylistMetricIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 6h10M4 11h10M4 16h7"/><circle cx="17" cy="17" r="3"/><path d="M20 17V7l-6 1.5"/></svg>`;
const serverDeviceIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m5 12 4 4L19 6"/></svg>`;
const escapeHTML = (value) => String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" }[character]));
const currentTrack = () => state.tracks.find((track) => track.id === currentID) || null;
const playlistTracks = () => selectedPlaylistID ? tracksForPlaylist(state, selectedPlaylistID) : state.tracks;

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

function currentSearchQuery() {
  if (section === "library") return libraryQuery;
  if (section === "playlists") return playlistQuery;
  if (section === "storage") return storageQuery;
  return serverQuery;
}

function currentSearchPlaceholder() {
  if (section === "library" && selectedPlaylistID) {
    const playlist = state.playlists.find((item) => item.id === selectedPlaylistID);
    return `Search ${playlist?.name || "this playlist"}…`;
  }
  if (section === "library") return "Search your library…";
  if (section === "playlists") return "Search playlists…";
  if (section === "storage") return storageScope === "downloads" ? "Search downloaded songs…" : storageScope === "files" ? "Search imported files…" : "Search stored songs…";
  return "Search server library…";
}

function updateTopSearch() {
  const input = $("#search");
  const sort = $("#searchSort");
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
  else serverQuery = value;
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

function updatePlaylistSyncUI() {
  document.querySelectorAll("[data-playlist-sync-status]").forEach((element) => {
    element.textContent = playlistSyncText;
    element.setAttribute("role", "status");
    element.setAttribute("aria-live", "polite");
  });
}

function setPlaylistSyncText(value) {
  playlistSyncText = value;
  updatePlaylistSyncUI();
}

function normalizedServerKey(value) {
  const url = new URL(String(value || "").trim());
  if (url.protocol !== "https:" && url.protocol !== "http:") throw new Error("Enter a complete http:// or https:// server URL.");
  url.hash = "";
  url.search = "";
  url.pathname = url.pathname.replace(/\/+$/, "") + "/";
  return url.href;
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
      if (!automatic) setPlaylistSyncText("Enter the server access token");
      return;
    }

    try {
      const serverKey = normalizedServerKey(state.serverURL);
      if (state.playlistSyncServerURL !== serverKey) {
        state.playlistSyncServerURL = serverKey;
        state.playlistRevision = 0;
        state.knownRemotePlaylistIDs = [];
        state.deletedPlaylistIDs = [];
        state.dirtyPlaylistIDs = state.playlists.filter((playlist) => !playlist.isSystem).map((playlist) => playlist.id);
      }

      setPlaylistSyncText("Syncing playlists…");
      let remoteDocument = await api.fetchPlaylists({ baseURL: state.serverURL, token: serverToken });
      for (let attempt = 0; attempt < 2; attempt += 1) {
        const merge = mergePlaylistDocument(state, remoteDocument);
        if (!merge.needsUpload) {
          applyRemotePlaylistDocument(state, remoteDocument);
          await persist();
          setPlaylistSyncText(`Synced ${remoteDocument.playlists.length} playlist${remoteDocument.playlists.length === 1 ? "" : "s"}`);
          render();
          return;
        }

        const result = await api.putPlaylists({
          baseURL: state.serverURL,
          token: serverToken,
          document: merge.document,
        });
        if (result.status === 200) {
          state.dirtyPlaylistIDs = [];
          state.deletedPlaylistIDs = [];
          applyRemotePlaylistDocument(state, result.document);
          await persist();
          setPlaylistSyncText(`Synced ${result.document.playlists.length} playlist${result.document.playlists.length === 1 ? "" : "s"}`);
          render();
          return;
        }
        remoteDocument = result.document;
      }
      throw new Error("Playlist sync conflicted; try again");
    } catch (error) {
      setPlaylistSyncText(`Playlist sync failed: ${error.message || "Unknown error"}`);
    }
  })();

  try {
    await playlistSyncInFlight;
  } finally {
    playlistSyncInFlight = null;
  }
}

function artwork(track) {
  return `<div class="row-art">${track?.artwork ? `<img src="${escapeHTML(track.artwork)}" alt="">` : "♪"}</div>`;
}

function trackRow(track, index) {
  const liked = state.favorites.includes(track.id);
  const editablePlaylist = state.playlists.find((playlist) => playlist.id === selectedPlaylistID && !playlist.isSystem);
  const actionLabel = `Play ${track.title} by ${track.artist || "Unknown artist"}`;
  const reorderLabel = editablePlaylist ? ". Press Alt+Up or Alt+Down to reorder" : "";
  return `<div class="track-row ${track.id === currentID ? "playing" : ""} ${editablePlaylist ? "playlist-draggable" : ""}" data-track="${track.id}" tabindex="0" aria-label="${escapeHTML(actionLabel + reorderLabel)}" ${editablePlaylist ? 'draggable="true" data-playlist-draggable="true" aria-keyshortcuts="Alt+ArrowUp Alt+ArrowDown Shift+F10"' : 'aria-keyshortcuts="Enter Space Shift+F10"'}>
    <span class="track-number" title="${track.id === currentID && !audio.paused ? "Now playing" : `Track ${index + 1}`}">${track.id === currentID && !audio.paused ? nowPlayingIcon : index + 1}</span>${artwork(track)}
    <div class="track-copy"><strong>${escapeHTML(track.title)}</strong><small>${escapeHTML(track.artist)} / Audio</small></div>
    <span class="album">${escapeHTML(track.album)}</span><span class="track-time">${formatTime(track.duration)}</span>
    <button class="heart" data-favorite="${track.id}" aria-label="${liked ? "Remove from" : "Add to"} Liked Songs" aria-pressed="${liked}">${liked ? "♥" : "♡"}</button>
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
  updateTopSearch();
  const tracks = filterTracks(playlistTracks(), libraryQuery, libraryFilter);
  const selectedPlaylist = selectedPlaylistID ? state.playlists.find((item) => item.id === selectedPlaylistID) : null;
  const title = selectedPlaylist?.name || (selectedPlaylistID ? "Playlist" : "Library");
  const isLikedSongs = Boolean(selectedPlaylist?.isSystem);
  const editablePlaylist = Boolean(selectedPlaylist && !selectedPlaylist.isSystem);
  const collectionPlaying = isCurrentCollectionPlayback(tracks) && !audio.paused;
  const menuItems = [
    `<button type="button" role="menuitem" data-hero-import>Import Songs…</button>`,
    `<button type="button" role="menuitem" data-hero-next>Next Track</button>`,
    selectedPlaylist ? `<button type="button" role="menuitem" data-hero-sync>Sync Playlists</button>` : "",
    editablePlaylist ? `<button class="danger-item" type="button" role="menuitem" data-hero-delete>Delete Playlist</button>` : "",
  ].filter(Boolean).join("");
  const moreMenu = `<details class="playlist-more"><summary title="More options" aria-label="More options"><span aria-hidden="true">•••</span></summary><div class="playlist-menu" role="menu">${menuItems}</div></details>`;
  const heroActions = `<button class="primary playlist-play" id="playCollection"><span class="button-icon">${collectionPlaying ? playbackPauseIcon : playbackPlayIcon}</span><span>${collectionPlaying ? "Pause" : "Play"}</span></button><div class="playlist-action-cluster"><button class="${shuffle ? "active" : ""}" id="heroShuffle" title="Shuffle" aria-label="Shuffle" aria-pressed="${shuffle}">${shuffleIcon}</button><button id="heroAdd" title="${selectedPlaylist ? "Add songs" : "Import songs"}" aria-label="${selectedPlaylist ? "Add songs" : "Import songs"}">${plusIcon}</button>${moreMenu}</div>`;
  content.innerHTML = `<div class="collection-scroll"><div class="hero playlist-hero ${selectedPlaylist ? "" : "library-hero"} ${isLikedSongs ? "liked-songs-hero" : ""}"><div class="hero-art">${isLikedSongs ? likedSongsIcon : playlistNoteIcon}</div><div class="hero-body"><span class="eyebrow">${isLikedSongs ? "YOUR COLLECTION" : selectedPlaylistID ? "PLAYLIST" : "MUSIC LIBRARY"}</span><h1>${escapeHTML(title)}</h1><p>${tracks.length} tracks / Stored locally</p><div class="hero-actions">${heroActions}</div>${selectedPlaylist ? `<small class="playlist-hero-sync" data-playlist-sync-status>${escapeHTML(playlistSyncText)}</small>` : ""}</div></div>
    <div class="filters"><button class="${libraryFilter === "all" ? "active" : ""}" data-library-filter="all">All songs</button><button class="${libraryFilter === "recent" ? "active" : ""}" data-library-filter="recent">Recently added</button><button class="${libraryFilter === "audio" ? "active" : ""}" data-library-filter="audio">Audio</button></div>
    <div class="track-table"><div class="track-header"><span>#</span><span></span><span>Title</span><span>Album</span><span>Time</span><span></span></div>
    ${tracks.length ? tracks.map(trackRow).join("") : `<div class="empty"><b>${selectedPlaylistID ? "This playlist is empty" : "No songs yet"}</b><span>${selectedPlaylistID ? "Like songs or add them from your Library." : "Import audio files or connect your music server."}</span></div>`}</div></div>`;
  bindTrackRows(tracks);
  $("#playCollection").onclick = () => {
    if (isCurrentCollectionPlayback(tracks)) toggle();
    else if (tracks[0]) play(tracks[0], tracks, { playlistID: selectedPlaylistID });
  };
  $("#heroShuffle").onclick = () => {
    shuffle = !shuffle;
    state.shuffle = shuffle;
    persistInBackground();
    updateChrome();
    render();
  };
  $("#heroAdd").onclick = () => selectedPlaylist ? openAddSongsDialog(selectedPlaylist) : importAudio();
  document.querySelector("[data-hero-import]").onclick = importAudio;
  document.querySelector("[data-hero-next]").onclick = () => move(1);
  const syncButton = document.querySelector("[data-hero-sync]");
  if (syncButton) syncButton.onclick = () => syncPlaylistsNow();
  const deleteButton = document.querySelector("[data-hero-delete]");
  if (deleteButton) deleteButton.onclick = async () => {
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
  content.innerHTML = `<div class="page"><span class="eyebrow">YOUR COLLECTIONS</span><h1>Playlists</h1><p>Organize your music into collections shared across your Resonance devices.</p><div class="playlist-page-actions"><button class="primary" id="pageNewPlaylist">＋ New Playlist</button><button class="secondary" id="pageSyncPlaylists">Sync Playlists</button><small data-playlist-sync-status>${escapeHTML(playlistSyncText)}</small></div><div class="playlist-grid">${playlists.map((playlist) => `<button class="playlist-card" data-open-playlist="${playlist.id}"><div class="playlist-art">${playlist.isSystem ? "♥" : "♪"}</div><div><strong>${escapeHTML(playlist.name)}</strong><small>${playlist.trackIDs.length} tracks</small></div><span>›</span></button>`).join("") || `<div class="empty"><b>No matching playlists</b><span>Try a different playlist or song name.</span></div>`}</div></div>`;
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
  content.innerHTML = `<div class="page storage-page"><div class="page-title-row"><div><span class="eyebrow">ON THIS DEVICE</span><h1>Song Storage</h1></div><div class="page-title-actions"><button class="primary" id="storageImport">＋ Import</button><button class="secondary" id="storageEdit">${storageEditing ? "Done" : "Edit"}</button></div></div>
    <div class="storage-summary" id="storageSummary"><div class="storage-ring" style="--local:${localDegrees}deg"><span>♪</span></div><div class="storage-stat"><small>Local audio</small><strong>${formatBytes(localBytes)}</strong><span>${localTracks.length} files</span></div><div class="storage-stat"><small>Server downloads</small><strong>${formatBytes(remoteBytes)}</strong><span>${remoteTracks.length} files</span></div><div class="storage-stat"><small>Available</small><strong id="storageAvailable">Calculating…</strong><span id="storageFreePercent">Disk space</span></div></div>
    <div class="segmented storage-tabs"><button class="${storageScope === "songs" ? "active" : ""}" data-storage-scope="songs">Songs</button><button class="${storageScope === "downloads" ? "active" : ""}" data-storage-scope="downloads">Downloads</button><button class="${storageScope === "files" ? "active" : ""}" data-storage-scope="files">Files</button></div>
    ${storageEditing ? `<div class="selection-bar"><span>${selectedStorageIDs.size} selected</span><button class="danger" id="deleteSelectedStorage" ${selectedStorageIDs.size ? "" : "disabled"}>Delete selected</button></div>` : ""}
    <div class="storage-section-heading"><strong>${storageScope === "downloads" ? "DOWNLOADED FROM SERVER" : storageScope === "files" ? "IMPORTED ON THIS PC" : "ALL SONGS"}</strong><span>${tracks.length} songs</span></div>
    <div class="storage-list redesigned">${tracks.map((track) => `<div class="storage-row ${storageEditing ? "selecting" : ""}"><button class="storage-select ${selectedStorageIDs.has(track.id) ? "selected" : ""}" data-storage-select="${track.id}" ${storageEditing ? "" : "hidden"}>${selectedStorageIDs.has(track.id) ? "✓" : "○"}</button>${artwork(track)}<span class="track-details"><strong>${escapeHTML(track.title)}</strong><small>${escapeHTML(track.artist || "Unknown Artist")} • ${escapeHTML(track.album || "Unknown Album")}</small></span><span class="storage-size">${formatBytes(track.size)}</span><button class="row-menu" data-delete="${track.id}" title="Remove from this device">•••</button></div>`).join("") || `<div class="empty"><b>No matching songs</b><span>Try another filter or import audio.</span></div>`}</div></div>`;
  $("#storageImport").onclick = importAudio;
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
      <span id="serverStatus" class="connection-pill ${connected ? "connected" : ""}">● ${escapeHTML(connected ? "Connected" : serverConnectInFlight ? "Connecting" : "Offline")}</span><span class="server-connection-detail" role="status" aria-live="polite">${escapeHTML(serverConnectionText)}</span>
      <button class="server-url" id="serverSettings" title="Edit server connection"><span>${escapeHTML(state.serverURL || "Add a server connection")}</span><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m4 20 4.5-1 10-10-3.5-3.5-10 10zM13.5 7l3.5 3.5"/></svg></button>
      <span class="server-dot">•</span><span class="server-inline-metric purple">${serverSongIcon}<strong id="serverSongCount">${serverCatalog.length}</strong><span>songs</span></span>
      <span class="server-dot">•</span><span class="server-inline-metric violet">${serverPlaylistMetricIcon}<strong>${playlistCount}</strong><span>playlists</span></span>
      <span class="server-dot">•</span><span class="server-inline-metric green">${serverDeviceIcon}<strong>${downloaded}</strong><span>on device</span></span>
      <span class="server-sync-detail" data-playlist-sync-status>${escapeHTML(playlistSyncText)}</span>
    </div></div>
    <div class="server-library-bar"><div><strong>SERVER LIBRARY</strong><span id="remoteCount">${filteredCount} songs</span></div><div class="server-actions">
      <button id="uploadServer" title="Upload songs" aria-label="Upload songs">${serverUploadIcon}</button>
      <button id="syncAll" title="Download all songs" aria-label="Download all songs">${serverDownloadIcon}</button>
      <button id="syncSelected" class="${serverSelecting ? "active" : ""}" title="${selectLabel}" aria-label="${selectLabel}" aria-pressed="${serverSelecting}">${serverSelectIcon}${selectedRemoteIDs.size ? `<b>${selectedRemoteIDs.size}</b>` : ""}</button>
      <button id="syncServerPlaylists" title="Sync playlists" aria-label="Sync playlists">${serverRefreshIcon}</button>
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
  $("#syncServerPlaylists").onclick = (event) => {
    const button = event.currentTarget;
    button.classList.remove("refresh-spinning");
    void button.offsetWidth;
    button.classList.add("refresh-spinning");
    button.addEventListener("animationend", () => button.classList.remove("refresh-spinning"), { once: true });
    syncPlaylistsNow();
  };
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
      ${artwork(song)}
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
    await api.deleteServerSong({ baseURL: state.serverURL, adminToken: serverAdminToken, songID: song.id });
    await serverAction("catalog");
  });
}

function openServerSettings() {
  $("#serverURL").value = state.serverURL || "";
  $("#serverToken").value = serverToken;
  $("#serverAdminToken").value = serverAdminToken;
  $("#serverSettingsDialog").showModal();
}

async function saveServerForm() {
  state.serverURL = $("#serverURL")?.value.trim() || state.serverURL;
  serverToken = $("#serverToken")?.value || serverToken;
  serverAdminToken = $("#serverAdminToken")?.value || serverAdminToken;
  await api.saveServerCredentials({ clientToken: serverToken, adminToken: serverAdminToken });
  await persist();
  schedulePlaylistSync();
}

function render() {
  if (section === "library") renderLibrary();
  else if (section === "playlists") renderPlaylists();
  else if (section === "storage") renderStorage();
  else renderServer();
  renderSidebar();
  renderQueue();
  $("#navBack").disabled = navigationIndex === 0;
  $("#navForward").disabled = navigationIndex + 1 >= navigationHistory.length;
  updatePlaylistSyncUI();
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
      const nextIndex = keyEvent.key === "Home" ? 0
        : keyEvent.key === "End" ? items.length - 1
          : (currentIndex + (keyEvent.key === "ArrowUp" ? -1 : 1) + items.length) % items.length;
      items[nextIndex].focus();
    }
  };
  requestAnimationFrame(() => menu.querySelector('[role="menuitem"]:not(:disabled)')?.focus());
  const removeButton = menu.querySelector("[data-context-remove-playlist-track]");
  if (removeButton) removeButton.onclick = async () => {
    activePlaylist.trackIDs = activePlaylist.trackIDs.filter((id) => id !== trackID);
    updatePlaylistRemoteSongIDs(state, activePlaylist);
    markPlaylistDirty(activePlaylist);
    if (activePlaybackPlaylistID === activePlaylist.id) setPlaybackContext(tracksForPlaylist(state, activePlaylist.id), activePlaylist.id);
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

function renderAddSongsDialog() {
  const playlist = state.playlists.find((item) => item.id === addSongsPlaylistID);
  if (!playlist) {
    $("#addSongsDialog").close();
    return;
  }
  $("#addSongsPlaylistName").textContent = playlist.name;
  const query = $("#addSongsSearch").value.trim().toLocaleLowerCase();
  const tracks = state.tracks.filter((track) => `${track.title} ${track.artist} ${track.album}`.toLocaleLowerCase().includes(query));
  $("#addSongsList").innerHTML = tracks.length ? tracks.map((track) => {
    const added = playlist.isSystem ? state.favorites.includes(track.id) : playlist.trackIDs.includes(track.id);
    return `<div class="add-song-row">${artwork(track)}<div><strong>${escapeHTML(track.title)}</strong><small>${escapeHTML(track.artist || "Local file")}</small></div><button class="${added ? "added" : ""}" data-add-song="${escapeHTML(track.id)}" aria-label="${added ? `Remove ${escapeHTML(track.title)}` : `Add ${escapeHTML(track.title)}`}">${added ? checkIcon : plusIcon}</button></div>`;
  }).join("") : `<div class="add-songs-empty"><b>No matching songs</b><span>Try a different title, artist, or album.</span></div>`;
}

function openAddSongsDialog(playlist) {
  addSongsPlaylistID = playlist.id;
  $("#addSongsSearch").value = "";
  renderAddSongsDialog();
  $("#addSongsDialog").showModal();
  requestAnimationFrame(() => $("#addSongsSearch").focus());
}

function updateServerTransfer({ direction, currentFile, completed = 0, total = 1 }) {
  if (serverTransferCancelRequested) return;
  const toast = $("#serverTransferToast");
  if (!toast) return;
  const ratio = total ? Math.min(1, completed / total) : 0;
  serverTransferActive = true;
  toast.hidden = false;
  toast.dataset.direction = direction;
  $("#serverTransferIcon").innerHTML = direction === "upload" ? serverUploadIcon : serverDownloadIcon;
  $("#serverTransferTitle").textContent = direction === "upload" ? "Uploading" : "Downloading";
  $("#serverTransferDetail").textContent = currentFile || "Preparing transfer…";
  $("#serverTransferProgress").value = ratio;
  $("#serverTransferPercent").textContent = `${Math.round(ratio * 100)}%`;
  if (total > 0 && completed >= total) hideServerTransfer();
}

function hideServerTransfer() {
  const toast = $("#serverTransferToast");
  if (toast) toast.hidden = true;
  const cancel = $("#dismissServerTransfer");
  if (cancel) cancel.disabled = false;
  serverTransferActive = false;
}

async function cancelServerTransfer() {
  if (!serverTransferActive || serverTransferCancelRequested) return;
  serverTransferCancelRequested = true;
  $("#serverTransferDetail").textContent = "Cancelling transfer…";
  $("#dismissServerTransfer").disabled = true;
  try {
    await api.cancelServerTransfer();
  } finally {
    hideServerTransfer();
  }
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
      const result = await api.syncServer({ baseURL: url, token, existing: state.tracks, songIDs });
      catalog = result.catalog;
      transferCancelled = Boolean(result.cancelled || serverTransferCancelRequested);
      mergeSyncedTracks(state, result);
      serverConnectionText = transferCancelled
        ? `Download cancelled${result.downloaded.length ? ` • ${result.downloaded.length} completed` : ""}`
        : `Synced ${result.downloaded.length} new song${result.downloaded.length === 1 ? "" : "s"}`;
      selectedRemoteIDs.clear();
      await persist();
    } else {
      catalog = await api.fetchCatalog({ baseURL: url, token });
      serverConnectionText = `Connected • ${catalog.count} song${catalog.count === 1 ? "" : "s"}`;
    }
    if (catalog) {
      state.serverURL = url;
      serverCatalog = catalog.songs || [];
    }
    await persist();
    renderSidebar();
    if (!transferCancelled) await syncPlaylistsNow({ automatic: true });
  } catch (error) {
    serverConnectionText = serverTransferCancelRequested ? "Download cancelled" : error.message || "Connection failed";
    if (!serverTransferCancelRequested) showNotice(serverConnectionText);
  } finally {
    serverConnectInFlight = false;
    if (mode !== "catalog") {
      hideServerTransfer();
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
    const result = await api.uploadServer({ baseURL: state.serverURL, adminToken: serverAdminToken });
    const cancelled = Boolean(result.cancelled || serverTransferCancelRequested);
    serverConnectionText = cancelled
      ? `Upload cancelled${result.uploaded ? ` • ${result.uploaded} completed` : ""}`
      : `Uploaded ${result.uploaded} song${result.uploaded === 1 ? "" : "s"}`;
    if (status) status.textContent = serverConnectionText;
    if (cancelled) {
      const catalog = await api.fetchCatalog({ baseURL: state.serverURL, token: serverToken });
      serverCatalog = catalog.songs || [];
      if (section === "server") renderServer();
    } else {
      await serverAction("catalog");
    }
  } catch (error) {
    serverConnectionText = serverTransferCancelRequested ? "Upload cancelled" : error.message || "Upload failed";
    if (status) status.textContent = serverConnectionText;
    if (!serverTransferCancelRequested) showNotice(serverConnectionText);
  } finally {
    hideServerTransfer();
    serverTransferCancelRequested = false;
  }
}

async function requestPlayback() {
  try {
    await audio.play();
  } catch (error) {
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
  state.favorites = state.favorites.includes(id) ? state.favorites.filter((item) => item !== id) : [...state.favorites, id];
  persistInBackground(); render(); updateChrome();
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
$("#dismissAppNotice").onclick = dismissNotice;
$("#dismissServerTransfer").onclick = cancelServerTransfer;
$("#cancelPlaylist").onclick = () => { pendingPlaylistTrackID = null; $("#playlistDialog").close(); };
$("#closeAddSongs").onclick = () => $("#addSongsDialog").close();
$("#addSongsSearch").oninput = renderAddSongsDialog;
$("#addSongsList").onclick = async (event) => {
  const button = event.target.closest("[data-add-song]");
  if (!button) return;
  const playlist = state.playlists.find((item) => item.id === addSongsPlaylistID);
  if (!playlist) return;
  button.disabled = true;
  const added = playlist.isSystem ? state.favorites.includes(button.dataset.addSong) : playlist.trackIDs.includes(button.dataset.addSong);
  if (playlist.isSystem) {
    state.favorites = added
      ? state.favorites.filter((id) => id !== button.dataset.addSong)
      : [...new Set([...state.favorites, button.dataset.addSong])];
  } else {
    playlist.trackIDs = added
      ? playlist.trackIDs.filter((id) => id !== button.dataset.addSong)
      : [...playlist.trackIDs, button.dataset.addSong];
    updatePlaylistRemoteSongIDs(state, playlist);
    markPlaylistDirty(playlist);
  }
  await persist();
  if (!playlist.isSystem) schedulePlaylistSync();
  renderAddSongsDialog();
};
$("#addSongsDialog").addEventListener("close", () => {
  addSongsPlaylistID = null;
  if (section === "library") renderLibrary();
});
$("#cancelServerSettings").onclick = () => $("#serverSettingsDialog").close();
$("#serverSettingsForm").onsubmit = async (event) => {
  event.preventDefault();
  serverAutoAttempted = true;
  await saveServerForm();
  $("#serverSettingsDialog").close();
  if (section === "server") await serverAction("catalog");
};
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
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    closeTrackContextMenu();
    closeSearchSort();
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
$("#speed").onchange = (event) => { audio.playbackRate = Number(event.target.value); state.playbackRate = audio.playbackRate; persistInBackground(); };
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
  schedulePlaybackProgressSave();
};
audio.onplay = () => { updateChrome(); renderQueue(); };
audio.onpause = () => {
  updateChrome();
  if (playbackProgressTimer) {
    clearTimeout(playbackProgressTimer);
    playbackProgressTimer = null;
  }
  persistInBackground({ refreshSidebar: false });
};
audio.onended = () => repeat ? play(currentTrack(), null, { recordHistory: false }) : move(1);
audio.onerror = () => {
  updateChrome();
  showNotice("This song could not be played. The file may be missing, inaccessible, or unsupported.");
};
audio.onloadedmetadata = async () => {
  const track = currentTrack();
  if (pendingRestorePosition !== null && audio.duration) {
    audio.currentTime = Math.min(pendingRestorePosition, Math.max(0, audio.duration - 0.25));
    state.position = audio.currentTime;
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
({ clientToken: serverToken = "", adminToken: serverAdminToken = "" } = await api.loadServerCredentials());
shuffle = Boolean(state.shuffle); repeat = Boolean(state.repeat);
state.volume = normalizedVolume(state.volume);
$("#volume").value = state.volume;
paintRange($("#volume"));
paintRange($("#seek"));
$("#speed").value = String(state.playbackRate || 1);
$("#volumeText").textContent = `${Math.round(state.volume * 100)}%`;
currentID = state.currentTrackID && state.tracks.some((track) => track.id === state.currentTrackID) ? state.currentTrackID : state.tracks[0]?.id || null;
activePlaybackQueueIDs = state.playbackQueueIDs.length ? [...state.playbackQueueIDs] : state.tracks.map((track) => track.id);
activePlaybackPlaylistID = state.playbackPlaylistID;
state.playbackQueueIDs = [...activePlaybackQueueIDs];
if (currentID) {
  const track = currentTrack();
  pendingRestorePosition = Math.max(0, Number(state.position) || 0);
  audio.src = track.fileUrl;
  audio.volume = state.volume;
  audio.playbackRate = Number(state.playbackRate) || 1;
}
if (libraryLoad?.warning) showNotice(libraryLoad.warning);
api.onTransferProgress((value) => {
  updateServerTransfer(value);
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
setInterval(() => syncPlaylistsNow({ automatic: true }), 60000);
