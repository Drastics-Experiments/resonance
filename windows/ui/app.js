import {
  applyRemotePlaylistDocument,
  createEmptyState,
  filterPlaylists,
  filterTracks,
  formatTime,
  mergePlaylistDocument,
  mergeSyncedTracks,
  nextIndex,
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
let navigationHistory = [{ section: "library", playlistID: null }];
let navigationIndex = 0;
let pendingPlaylistTrackID = null;
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

const $ = (selector) => document.querySelector(selector);
const shuffleIcon = `<svg class="shuffle-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h2.5a5 5 0 0 1 4 2l5 7a5 5 0 0 0 4 2H21"/><path d="m17 13 4 4-4 4"/><path d="M3 18h2.5a5 5 0 0 0 4-2l5-7a5 5 0 0 1 4-2H21"/><path d="m17 3 4 4-4 4"/></svg>`;
const playbackPlayIcon = `<svg class="transport-icon" viewBox="0 0 24 24" aria-hidden="true"><path class="icon-fill" d="M8 5v14l11-7z"/></svg>`;
const playbackPauseIcon = `<svg class="transport-icon" viewBox="0 0 24 24" aria-hidden="true"><rect class="icon-fill" x="6" y="5" width="4.5" height="14" rx="1.5"/><rect class="icon-fill" x="13.5" y="5" width="4.5" height="14" rx="1.5"/></svg>`;
const nowPlayingIcon = `<svg class="now-playing-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M3.5 9.5h4l5-4v13l-5-4h-4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7"/><path d="M18.5 5.5a9 9 0 0 1 0 13"/></svg>`;
const escapeHTML = (value) => String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" }[character]));
const currentTrack = () => state.tracks.find((track) => track.id === currentID) || null;
const playlistTracks = () => selectedPlaylistID ? tracksForPlaylist(state, selectedPlaylistID) : state.tracks;

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
    sort.setAttribute("aria-label", "Sort storage results");
    sort.innerHTML = '<option value="title">Title</option><option value="recent">Recently added</option><option value="size">File size</option>';
    sort.value = storageSort;
  } else if (section === "server") {
    sort.hidden = false;
    sort.setAttribute("aria-label", "Sort server results");
    sort.innerHTML = '<option value="title">Title</option><option value="artist">Artist</option><option value="size">File size</option>';
    sort.value = serverSort;
  } else {
    sort.hidden = true;
    sort.replaceChildren();
  }
}

function setCurrentSearchQuery(value) {
  if (section === "library") libraryQuery = value;
  else if (section === "playlists") playlistQuery = value;
  else if (section === "storage") storageQuery = value;
  else serverQuery = value;
}

async function persist() {
  normalizeState(state);
  await api.saveLibrary(state);
  renderSidebar();
}

function updatePlaylistSyncUI() {
  document.querySelectorAll("[data-playlist-sync-status]").forEach((element) => {
    element.textContent = playlistSyncText;
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
  const playlistActions = editablePlaylist
    ? `<div class="playlist-track-actions"><button data-reorder-track="-1" data-playlist-track="${track.id}" title="Move up">↑</button><button data-reorder-track="1" data-playlist-track="${track.id}" title="Move down">↓</button><button data-remove-playlist-track="${track.id}" title="Remove from playlist">×</button></div>`
    : `<span></span>`;
  return `<div class="track-row ${track.id === currentID ? "playing" : ""}" data-track="${track.id}">
    <span class="track-number" title="${track.id === currentID && !audio.paused ? "Now playing" : `Track ${index + 1}`}">${track.id === currentID && !audio.paused ? nowPlayingIcon : index + 1}</span>${artwork(track)}
    <div class="track-copy"><strong>${escapeHTML(track.title)}</strong><small>${escapeHTML(track.artist)} / Audio</small></div>
    <span class="album">${escapeHTML(track.album)}</span><span class="track-time">${formatTime(track.duration)}</span>
    <button class="heart" data-favorite="${track.id}">${liked ? "♥" : "♡"}</button>${playlistActions}
  </div>`;
}

function renderLibrary() {
  updateTopSearch();
  const tracks = filterTracks(playlistTracks(), libraryQuery, libraryFilter);
  const selectedPlaylist = selectedPlaylistID ? state.playlists.find((item) => item.id === selectedPlaylistID) : null;
  const title = selectedPlaylist?.name || (selectedPlaylistID ? "Playlist" : "Library");
  const playlistControls = selectedPlaylist && !selectedPlaylist.isSystem
    ? `<button class="danger" id="deletePlaylist">Delete playlist</button><small data-playlist-sync-status>${escapeHTML(playlistSyncText)}</small>`
    : "";
  content.innerHTML = `<div class="collection-scroll"><div class="hero"><div class="hero-art">≋</div><div><span class="eyebrow">${selectedPlaylistID ? "PLAYLIST" : "MUSIC LIBRARY"}</span><h1>${escapeHTML(title)}</h1><p>${tracks.length} tracks / Stored locally</p><div class="hero-actions"><button class="primary" id="playCollection"><span class="button-icon">${audio.paused ? playbackPlayIcon : playbackPauseIcon}</span><span>${audio.paused ? "Play" : "Pause"}</span></button><button class="round ${shuffle ? "active" : ""}" id="heroShuffle" title="Shuffle" aria-label="Shuffle">${shuffleIcon}</button><button class="secondary" id="importAudio">＋ Import audio</button>${playlistControls}</div></div></div>
    <div class="filters"><button class="${libraryFilter === "all" ? "active" : ""}" data-library-filter="all">All songs</button><button class="${libraryFilter === "recent" ? "active" : ""}" data-library-filter="recent">Recently added</button><button class="${libraryFilter === "audio" ? "active" : ""}" data-library-filter="audio">Audio</button></div>
    <div class="track-table"><div class="track-header"><span>#</span><span></span><span>Title</span><span>Album</span><span>Time</span><span></span><span>${selectedPlaylist && !selectedPlaylist.isSystem ? "Order" : ""}</span></div>
    ${tracks.length ? tracks.map(trackRow).join("") : `<div class="empty"><b>${selectedPlaylistID ? "This playlist is empty" : "No songs yet"}</b><span>${selectedPlaylistID ? "Like songs or add them from your Library." : "Import audio files or connect your music server."}</span></div>`}</div></div>`;
  bindTrackRows();
  $("#importAudio").onclick = importAudio;
  $("#playCollection").onclick = () => currentTrack() ? toggle() : tracks[0] && play(tracks[0]);
  $("#heroShuffle").onclick = () => { shuffle = !shuffle; updateChrome(); render(); };
  if ($("#deletePlaylist")) $("#deletePlaylist").onclick = async () => {
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
  for (const track of tracks) await api.deleteAudio(track.filePath);
  const removed = new Set(tracks.map((track) => track.id));
  state.tracks = state.tracks.filter((track) => !removed.has(track.id));
  state.favorites = state.favorites.filter((id) => !removed.has(id));
  state.playlists.forEach((playlist) => { playlist.trackIDs = playlist.trackIDs.filter((id) => !removed.has(id)); });
  if (removed.has(currentID)) { audio.pause(); currentID = null; }
  selectedStorageIDs.clear();
  await persist();
  render();
  updateChrome();
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
  }).catch(() => {});
}

function renderServer() {
  updateTopSearch();
  const downloaded = serverCatalog.filter((song) => state.tracks.some((track) => track.remoteID === song.id)).length;
  const filteredCount = filteredServerCatalog().length;
  content.innerHTML = `<div class="page server-page"><div class="server-heading"><div><h1>Music Server</h1><p><span class="connection-pill ${serverCatalog.length ? "connected" : ""}">● ${escapeHTML(serverCatalog.length ? "Connected" : serverConnectInFlight ? "Connecting" : "Offline")}</span> ${escapeHTML(state.serverURL || "Add a server connection")}</p></div></div>
    <button class="connection-card" id="serverSettings"><span class="connection-icon">◎</span><span><strong>Connection</strong><small>${escapeHTML(state.serverURL || "Configure server URL and access keys")}</small></span><span class="masked-key">◆ ${serverToken ? "•••• •••• ••••" : "No token"}</span><b>⚙</b></button>
    <div class="server-metrics"><div><span class="metric-icon purple">♪</span><strong id="serverSongCount">${serverCatalog.length}</strong><small>songs</small></div><div><span class="metric-icon violet">≡</span><strong>${state.playlists.filter((playlist) => !playlist.isSystem).length}</strong><small>playlists</small></div><div><span class="metric-icon green">✓</span><strong>${serverCatalog.length && downloaded === serverCatalog.length ? "All" : downloaded}</strong><small>${serverCatalog.length && downloaded === serverCatalog.length ? "synced" : "on device"}</small></div></div>
    <div class="server-actions"><button class="secondary" id="uploadServer">⇧ Upload</button><button class="secondary" id="syncSelected" ${selectedRemoteIDs.size ? "" : "disabled"}>⇩ Download${selectedRemoteIDs.size ? ` (${selectedRemoteIDs.size})` : ""}</button><button class="secondary" id="syncAll">⇩ Download all</button><button class="secondary" id="syncServerPlaylists">≡ Sync playlists</button></div>
    <div class="server-transfer"><div class="transfer-header"><strong id="serverStatus">${escapeHTML(serverConnectionText)}</strong><small data-playlist-sync-status>${escapeHTML(playlistSyncText)}</small></div><div class="transfer-grid"><div><span class="metric-icon violet">↓</span><span><b>Downloading</b><small id="downloadDetail">Idle</small></span><progress id="downloadProgress" max="1" value="0"></progress></div><div><span class="metric-icon blue">↑</span><span><b>Uploading</b><small id="uploadDetail">Idle</small></span><progress id="uploadProgress" max="1" value="0"></progress></div></div></div>
    <div class="segmented server-tabs"><button class="${serverScope === "all" ? "active" : ""}" data-server-scope="all">All</button><button class="${serverScope === "device" ? "active" : ""}" data-server-scope="device">On Device</button><button class="${serverScope === "available" ? "active" : ""}" data-server-scope="available">Not Downloaded</button></div>
    <div class="remote-heading"><strong>SERVER LIBRARY</strong><span id="remoteCount">${filteredCount} songs</span><button id="toggleServerSelect">${serverSelecting ? "Done" : "Select"}</button></div><div id="remoteSongs" class="remote-list redesigned">${serverCatalog.length ? remoteRows() : `<div class="empty"><span>${serverConnectInFlight ? "Connecting to your server…" : "Open connection settings to connect."}</span></div>`}</div></div>`;
  $("#serverSettings").onclick = openServerSettings;
  $("#toggleServerSelect").onclick = () => { serverSelecting = !serverSelecting; if (!serverSelecting) selectedRemoteIDs.clear(); renderServer(); };
  document.querySelectorAll("[data-server-scope]").forEach((button) => button.onclick = () => { serverScope = button.dataset.serverScope; renderServer(); });
  $("#syncSelected").onclick = () => serverAction("selected");
  $("#syncAll").onclick = () => serverAction("all");
  $("#uploadServer").onclick = uploadServerSongs;
  $("#syncServerPlaylists").onclick = () => syncPlaylistsNow();
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
    return `<div class="remote-row ${serverSelecting ? "selecting" : ""}"><button class="remote-check ${selectedRemoteIDs.has(song.id) ? "selected" : ""}" data-select-remote="${song.id}" ${serverSelecting ? "" : "hidden"}>${selectedRemoteIDs.has(song.id) ? "✓" : "○"}</button>${artwork(song)}<span class="track-details"><strong>${escapeHTML(song.title || song.name)}</strong><small>${escapeHTML(song.artist || "Unknown Artist")} • ${escapeHTML(song.album || "Server Library")}</small></span><span class="storage-size">${formatBytes(song.size)}</span><b class="sync-state">${onDevice ? "✓ On device" : "⇩ Available"}</b><button class="row-menu" data-delete-remote="${song.id}" title="Delete from server">•••</button></div>`;
  }).join("");
}

function bindRemoteRows() {
  document.querySelectorAll("[data-select-remote]").forEach((button) => button.onclick = () => { selectedRemoteIDs.has(button.dataset.selectRemote) ? selectedRemoteIDs.delete(button.dataset.selectRemote) : selectedRemoteIDs.add(button.dataset.selectRemote); renderServer(); });
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

function bindTrackRows() {
  document.querySelectorAll("[data-track]").forEach((row) => {
    row.onclick = (event) => {
      if (event.target.closest("button, select, input, a")) return;
      play(state.tracks.find((track) => track.id === row.dataset.track));
    };
    row.oncontextmenu = (event) => openTrackContextMenu(event, row.dataset.track);
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
    await persist();
    schedulePlaylistSync();
    renderLibrary();
  });
}

function closeTrackContextMenu() {
  const menu = $("#trackContextMenu");
  menu.hidden = true;
  menu.innerHTML = "";
}

function openTrackContextMenu(event, trackID) {
  event.preventDefault();
  const menu = $("#trackContextMenu");
  const track = state.tracks.find((item) => item.id === trackID);
  if (!track) return;
  const playlists = state.playlists.filter((item) => !item.isSystem);
  menu.innerHTML = `<div class="context-heading"><small>ADD TO PLAYLIST</small><strong>${escapeHTML(track.title)}</strong></div>${playlists.length ? playlists.map((playlist) => {
    const added = playlist.trackIDs.includes(trackID);
    return `<button role="menuitem" data-context-playlist="${escapeHTML(playlist.id)}" ${added ? "disabled" : ""}><span>${added ? "✓" : "＋"}</span>${escapeHTML(playlist.name)}</button>`;
  }).join("") : `<div class="context-empty">No playlists yet</div>`}<button role="menuitem" data-context-new><span>＋</span>Create new playlist…</button>`;
  menu.hidden = false;
  menu.style.left = `${Math.max(8, Math.min(event.clientX, innerWidth - menu.offsetWidth - 8))}px`;
  menu.style.top = `${Math.max(8, Math.min(event.clientY, innerHeight - menu.offsetHeight - 8))}px`;
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
  const tracks = await api.importAudio();
  state.tracks.push(...tracks);
  await persist();
  if (!currentID && tracks[0]) currentID = tracks[0].id;
  render(); updateChrome();
}

async function serverAction(mode) {
  if (serverConnectInFlight) return;
  const url = $("#serverURL")?.value.trim() || state.serverURL;
  const token = $("#serverToken")?.value || serverToken;
  serverToken = token;
  const status = $("#serverStatus");
  await saveServerForm();
  serverConnectInFlight = true;
  serverConnectionText = mode === "catalog" ? "Connecting…" : "Syncing downloads…";
  if (status) status.textContent = serverConnectionText;
  try {
    let catalog;
    if (mode !== "catalog") {
      const songIDs = mode === "selected" ? [...selectedRemoteIDs] : null;
      if (mode === "selected" && !songIDs.length) throw new Error("Select one or more songs first.");
      const result = await api.syncServer({ baseURL: url, token, existing: state.tracks, songIDs });
      catalog = result.catalog;
      mergeSyncedTracks(state, result);
      serverConnectionText = `Synced ${result.downloaded.length} new song${result.downloaded.length === 1 ? "" : "s"}`;
      selectedRemoteIDs.clear();
      await persist();
    } else {
      catalog = await api.fetchCatalog({ baseURL: url, token });
      serverConnectionText = `Connected • ${catalog.count} song${catalog.count === 1 ? "" : "s"}`;
    }
    state.serverURL = url;
    serverCatalog = catalog.songs || [];
    await persist();
    renderSidebar();
    await syncPlaylistsNow({ automatic: true });
  } catch (error) {
    serverConnectionText = error.message || "Connection failed";
  } finally {
    serverConnectInFlight = false;
    if (section === "server") renderServer();
  }
}

async function uploadServerSongs() {
  await saveServerForm();
  const status = $("#serverStatus");
  try {
    const result = await api.uploadServer({ baseURL: state.serverURL, adminToken: serverAdminToken });
    serverConnectionText = `Uploaded ${result.uploaded} song${result.uploaded === 1 ? "" : "s"}`;
    if (status) status.textContent = serverConnectionText;
    await serverAction("catalog");
  } catch (error) { serverConnectionText = error.message || "Upload failed"; if (status) status.textContent = serverConnectionText; }
}

function play(track) {
  if (!track) return;
  if (currentID && currentID !== track.id) history.push(currentID);
  currentID = track.id;
  state.currentTrackID = currentID;
  audio.src = track.fileUrl;
  audio.volume = Number(state.volume) || 0.78;
  audio.playbackRate = Number($("#speed").value) || 1;
  audio.play().catch((error) => console.error(error));
  persist(); updateChrome(); render();
}

function toggle() {
  const track = currentTrack();
  if (!track) { if (state.tracks[0]) play(state.tracks[0]); return; }
  if (!audio.currentSrc && !audio.src) { play(track); return; }
  audio.paused ? audio.play().catch((error) => console.error(error)) : audio.pause();
  updateChrome();
}

function move(direction) {
  const tracks = playlistTracks();
  const index = nextIndex(tracks, currentID, direction, shuffle);
  if (index >= 0) play(tracks[index]);
}

function toggleFavorite(id) {
  state.favorites = state.favorites.includes(id) ? state.favorites.filter((item) => item !== id) : [...state.favorites, id];
  persist(); render(); updateChrome();
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
  const tracks = playlistTracks();
  const index = tracks.findIndex((track) => track.id === currentID);
  const queue = index < 0 ? tracks : [...tracks.slice(index + 1), ...tracks.slice(0, index)];
  $("#queue").innerHTML = queue.slice(0, 12).map((track) => `<button data-queue="${track.id}">${artwork(track)}<span><strong>${escapeHTML(track.title)}</strong><small>${escapeHTML(track.artist)}</small></span><time>${formatTime(track.duration)}</time></button>`).join("") || `<div class="empty"><span>Queue is empty</span></div>`;
  document.querySelectorAll("[data-queue]").forEach((button) => button.onclick = () => play(state.tracks.find((track) => track.id === button.dataset.queue)));
}

function updateChrome() {
  const track = currentTrack();
  const playing = track && !audio.paused;
  $("#bottomTitle").textContent = track?.title || "Nothing playing";
  $("#bottomMeta").textContent = track ? `${track.artist} / ${playing ? "Now playing" : "Paused"}` : "Local library";
  $(".mini-art").innerHTML = track?.artwork ? `<img src="${escapeHTML(track.artwork)}" alt="">` : "♪";
  document.querySelectorAll("[data-action=toggle]").forEach((button) => {
    button.innerHTML = playing ? playbackPauseIcon : playbackPlayIcon;
    button.setAttribute("aria-label", playing ? "Pause" : "Play");
    button.title = playing ? "Pause" : "Play";
  });
  const collectionButton = $("#playCollection");
  if (collectionButton) collectionButton.innerHTML = `<span class="button-icon">${playing ? playbackPauseIcon : playbackPlayIcon}</span><span>${playing ? "Pause" : "Play"}</span>`;
  $("#favoriteCurrent").textContent = track && state.favorites.includes(track.id) ? "♥" : "♡";
  $("#shuffle").classList.toggle("active", shuffle);
  $("#repeat").classList.toggle("active", repeat);
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
document.querySelectorAll("[data-action=previous]").forEach((button) => button.onclick = () => history.length ? play(state.tracks.find((track) => track.id === history.pop())) : move(-1));
$("#newPlaylist").onclick = () => newPlaylist();
$("#cancelPlaylist").onclick = () => { pendingPlaylistTrackID = null; $("#playlistDialog").close(); };
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
document.addEventListener("click", (event) => { if (!event.target.closest("#trackContextMenu")) closeTrackContextMenu(); });
document.addEventListener("keydown", (event) => { if (event.key === "Escape") closeTrackContextMenu(); });
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
$("#searchSort").onchange = (event) => {
  if (section === "storage") {
    storageSort = event.target.value;
    renderStorage();
  } else if (section === "server") {
    serverSort = event.target.value;
    renderServer();
  }
};
$("#favoriteCurrent").onclick = () => currentID && toggleFavorite(currentID);
$("#shuffle").onclick = () => { shuffle = !shuffle; state.shuffle = shuffle; persist(); updateChrome(); };
$("#repeat").onclick = () => { repeat = !repeat; state.repeat = repeat; persist(); updateChrome(); };
$("#volume").oninput = async (event) => { audio.volume = Number(event.target.value); state.volume = audio.volume; $("#volumeText").textContent = `${Math.round(audio.volume * 100)}%`; await persist(); };
$("#speed").onchange = (event) => { audio.playbackRate = Number(event.target.value); state.playbackRate = audio.playbackRate; persist(); };
$("#seek").oninput = (event) => { if (audio.duration) audio.currentTime = audio.duration * Number(event.target.value) / 1000; };
audio.ontimeupdate = () => { $("#elapsed").textContent = formatTime(audio.currentTime); $("#duration").textContent = formatTime(audio.duration); $("#seek").value = audio.duration ? String(Math.round(audio.currentTime / audio.duration * 1000)) : "0"; state.position = audio.currentTime; };
audio.onplay = () => { updateChrome(); renderQueue(); };
audio.onpause = updateChrome;
audio.onended = () => repeat ? play(currentTrack()) : move(1);
audio.onloadedmetadata = async () => { const track = currentTrack(); if (track && audio.duration && track.duration !== audio.duration) { track.duration = audio.duration; await persist(); renderQueue(); } };

state = normalizeState(await api.loadLibrary());
({ clientToken: serverToken = "", adminToken: serverAdminToken = "" } = await api.loadServerCredentials());
shuffle = Boolean(state.shuffle); repeat = Boolean(state.repeat);
$("#volume").value = state.volume;
$("#speed").value = String(state.playbackRate || 1);
$("#volumeText").textContent = `${Math.round(state.volume * 100)}%`;
currentID = state.currentTrackID && state.tracks.some((track) => track.id === state.currentTrackID) ? state.currentTrackID : state.tracks[0]?.id || null;
api.onTransferProgress((value) => {
  const progress = document.querySelector(`#${value.direction}Progress`);
  const detail = document.querySelector(`#${value.direction}Detail`);
  if (progress) progress.value = value.total ? value.completed / value.total : 0;
  if (detail) detail.textContent = `${value.currentFile} • ${value.completed}/${value.total}`;
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
